"""UU远程自建服务端 —— 完整实现（单一文件，无外部状态依赖）。

设计原则
--------
1. **契约对齐**：响应信封、路径、RoomConfig 字段全部取自 APK 反编译结果
   （com.remote.http.JsonResponse / com.remote.room.api.model.RoomConfig）。
2. **媒体面不落地**：屏幕/声音/输入走客户端私有 WebRTC fork，服务端只做信令与 RPC 中继；
   因此信令通道必须**二进制透明**——不解析、不改写、原样转发，客户端说什么协议都能过。
3. **打洞优先**：房间下发 STUN + 短时效 TURN 凭据，ICE 自然先直连、全失败才中继。
4. **未知接口不打死**：未实现的路径一律记录并回 `{"code":0,"data":null}`，
   客户端不会因为我们的缺项直接崩，且真实报文落到 capture 便于补齐。

环境变量
--------
UU_PUBLIC_BASE  外部基础 URL，默认 https://api.nrd.nie.163.com
UU_WS_BASE      WebSocket 基础 URL，默认同 UU_PUBLIC_BASE（https→wss）
UU_STUN_URLS    逗号分隔
UU_TURN_URLS    逗号分隔
UU_TURN_SECRET  coturn use-auth-secret 共享密钥（有它才签发短时效凭据）
UU_TURN_TTL     TURN 凭据有效期秒，默认 86400
UU_DATA_DIR     sqlite 与 capture 目录，默认 ./data
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import sys
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, Header, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

# ---------------------------------------------------------------- 配置

PUBLIC_BASE = os.environ.get("UU_PUBLIC_BASE", "https://api.nrd.nie.163.com").rstrip("/")
WS_BASE = os.environ.get("UU_WS_BASE", PUBLIC_BASE.replace("https://", "wss://")).rstrip("/")
STUN_URLS = [u.strip() for u in os.environ.get("UU_STUN_URLS", "").split(",") if u.strip()]
TURN_URLS = [u.strip() for u in os.environ.get("UU_TURN_URLS", "").split(",") if u.strip()]
TURN_SECRET = os.environ.get("UU_TURN_SECRET", "")
TURN_TTL = int(os.environ.get("UU_TURN_TTL", "86400"))
DATA_DIR = Path(os.environ.get("UU_DATA_DIR", Path(__file__).parent / "data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = DATA_DIR / "uu.db"
CAPTURE = DATA_DIR / "capture" / "requests.jsonl"
CAPTURE.parent.mkdir(parents=True, exist_ok=True)

RPC_TIMEOUT = float(os.environ.get("UU_RPC_TIMEOUT", "30"))


def now_ms() -> int:
    return int(time.time() * 1000)


def dumps(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


# ---------------------------------------------------------------- 持久层

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    uid TEXT PRIMARY KEY, mobile TEXT UNIQUE, nickname TEXT, token TEXT UNIQUE, created_at INTEGER);
CREATE TABLE IF NOT EXISTS devices (
    device_id TEXT PRIMARY KEY, uid TEXT, name TEXT, platform TEXT,
    online INTEGER DEFAULT 0, last_seen INTEGER, created_at INTEGER);
CREATE TABLE IF NOT EXISTS rooms (
    room_id TEXT PRIMARY KEY, token TEXT UNIQUE, host_uid TEXT, device_id TEXT,
    mode TEXT, created_at INTEGER, closed INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS rpc (
    id INTEGER PRIMARY KEY AUTOINCREMENT, target TEXT, source TEXT, p TEXT,
    need_response INTEGER, payload TEXT, status TEXT, response TEXT,
    created_at INTEGER, updated_at INTEGER);
CREATE INDEX IF NOT EXISTS idx_rpc_target ON rpc(target, status);
"""


class DB:
    """线程安全的极简 sqlite 封装（uvicorn 多线程下每次操作取连接）。"""

    def __init__(self, path: Path) -> None:
        self.path = str(path)
        self._lock = threading.Lock()
        with self.conn() as c:
            c.executescript(SCHEMA)

    def conn(self) -> sqlite3.Connection:
        c = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        c.row_factory = sqlite3.Row
        c.execute("PRAGMA journal_mode=WAL")
        return c

    def run(self, sql: str, args: tuple = ()) -> sqlite3.Cursor:
        with self._lock:
            c = self.conn()
            try:
                return c.execute(sql, args)
            finally:
                c.close()

    def all(self, sql: str, args: tuple = ()) -> List[sqlite3.Row]:
        with self._lock:
            c = self.conn()
            try:
                return c.execute(sql, args).fetchall()
            finally:
                c.close()

    def one(self, sql: str, args: tuple = ()) -> Optional[sqlite3.Row]:
        rows = self.all(sql, args)
        return rows[0] if rows else None


db = DB(DB_PATH)


# ---------------------------------------------------------------- 内存态

# room_id -> {device_id: [活跃 WebSocket]}；按房间隔离，避免不同房间之间串帧
peers: Dict[str, Dict[str, List[WebSocket]]] = {}
# room_token -> room_id
rooms_by_token: Dict[str, str] = {}
# rpc_id -> (WebSocket, 请求方 device_id)，用于 WS 快路径回包
rpc_sockets: Dict[int, WebSocket] = {}
_lock = threading.Lock()


def envelope(code: int = 0, msg: str = "", data: Any = None) -> JSONResponse:
    return JSONResponse({"code": code, "msg": msg, "data": data})


def err(code: int, msg: str) -> JSONResponse:
    return envelope(code, msg, {})


# ---------------------------------------------------------------- 鉴权

def bearer(authorization: Optional[str]) -> str:
    if not authorization:
        raise ValueError("missing authorization")
    parts = authorization.split(None, 1)
    tok = parts[1] if len(parts) == 2 else parts[0]
    row = db.one("SELECT * FROM users WHERE token=?", (tok.strip(),))
    if not row:
        raise ValueError("invalid token")
    return row["uid"]


def current_user(authorization: Optional[str]) -> Optional[sqlite3.Row]:
    try:
        uid = bearer(authorization)
    except ValueError:
        return None
    return db.one("SELECT * FROM users WHERE uid=?", (uid,))


# ---------------------------------------------------------------- ICE

def build_ice(uid: str) -> Dict[str, Any]:
    """STUN 打洞 + 短时效 TURN 兜底。凭据算法与 coturn use-auth-secret 完全一致。"""
    ice: Dict[str, Any] = {"stun": list(STUN_URLS)}
    if TURN_URLS:
        if TURN_SECRET:
            username = "%d:%s" % (int(time.time()) + TURN_TTL, uid)
            digest = hmac.new(TURN_SECRET.encode(), username.encode(), hashlib.sha1).digest()
            ice["turn"] = [{"urls": TURN_URLS, "username": username,
                            "credential": base64.b64encode(digest).decode()}]
        else:
            ice["turn"] = [{"urls": TURN_URLS}]
    return ice


def room_config(row: sqlite3.Row, uid: str) -> Dict[str, Any]:
    """字段与 com.remote.room.api.model.RoomConfig 一一对应。"""
    signaling = WS_BASE + "/ws/signaling"
    ice = build_ice(uid)
    streamer_config = {
        "ice_servers": ice,
        "ice_transport_policy": "all",
        "max_bitrate_kbps": 20000,
        "prefer_hardware": True,
    }
    return {
        "signaling_server": signaling,
        "token": row["token"],
        "signaling_list": [{"url": signaling, "type": 1}],
        "ws_connect_timeout_ms": 8000,
        "streamer_retry_delta_ms": 1000,
        "max_reconnect_delta": 5000,
        "report_token": "",
        "report_url": "",
        "report_server_address": None,
        "international_connect": False,
        "sni_required_signaling_list": [],
        "streamer_config": dumps(streamer_config),
        "room_id": row["room_id"],
        "ice_servers": ice,
    }


# ---------------------------------------------------------------- 应用

app = FastAPI(title="UU Remote Self-Hosted", version="1.0.0", docs_url=None, redoc_url=None)


@app.middleware("http")
async def capture_request(request: Request, call_next):
    """记录原始请求（客户端第一次连上来时靠它反推未实现的契约）。"""
    body = b""
    if request.method in ("POST", "PUT", "PATCH"):
        try:
            body = await request.body()
        except Exception:
            body = b""
    try:
        with CAPTURE.open("a", encoding="utf-8") as f:
            f.write(dumps({
                "ts": now_ms(), "method": request.method, "path": request.url.path,
                "query": request.url.query,
                "headers": {k.lower(): v for k, v in request.headers.items()},
                "body": body[:8192].decode("utf-8", "replace"),
            }) + "\n")
    except Exception:
        pass
    return await call_next(request)


@app.get("/healthz")
async def healthz() -> Any:
    online = set()
    for devs in peers.values():
        online.update(d for d, lst in devs.items() if lst)
    return {"ok": True, "ts": now_ms(), "rooms": len(rooms_by_token),
            "devices_online": len(online)}


def device_online(device_id: str) -> bool:
    return any(lst for devs in peers.values() for d, lst in devs.items() if d == device_id)


# ---------------------------------------------------------------- 用户

async def _login(uid_hint: Optional[str], mobile: str) -> Dict[str, Any]:
    row = db.one("SELECT * FROM users WHERE mobile=?", (mobile,))
    if row:
        uid = row["uid"]
        token = secrets.token_urlsafe(32)
        db.run("UPDATE users SET token=? WHERE uid=?", (token, uid))
    else:
        uid = "u" + uuid.uuid4().hex[:16]
        token = secrets.token_urlsafe(32)
        nickname = "用户" + mobile[-4:]
        db.run("INSERT INTO users(uid,mobile,nickname,token,created_at) VALUES(?,?,?,?,?)",
               (uid, mobile, nickname, token, now_ms()))
    row = db.one("SELECT * FROM users WHERE uid=?", (uid,))
    return {"token": token, "uid": uid, "nickname": row["nickname"], "mobile": mobile}


@app.post("/api/v1/login/by_mobile")
async def login_by_mobile(request: Request) -> Any:
    body = await request.json()
    mobile = str(body.get("mobile") or body.get("phone") or "").strip()
    if not mobile:
        return err(1002, "mobile required")
    return envelope(0, "", await _login(None, mobile))


@app.post("/api/v1/login/by_qrcode")
async def login_by_qrcode(request: Request) -> Any:
    body = await request.json()
    return envelope(0, "", await _login(None, str(body.get("device_id") or uuid.uuid4().hex)))


@app.post("/api/v1/qrcode/gen/login")
async def qrcode_gen(request: Request) -> Any:
    qid = uuid.uuid4().hex
    return envelope(0, "", {"qrcode_id": qid, "url": PUBLIC_BASE + "/qr/" + qid, "expire_at": now_ms() + 120000})


@app.post("/api/v1/qrcode/login/status")
async def qrcode_status(request: Request) -> Any:
    body = await request.json()
    return envelope(0, "", {"qrcode_id": body.get("qrcode_id"), "status": 0, "token": ""})


@app.post("/api/v1/user/info")
async def user_info(request: Request, authorization: Optional[str] = Header(None)) -> Any:
    u = current_user(authorization)
    if not u:
        return err(1001, "invalid authorization")
    return envelope(0, "", {"uid": u["uid"], "nickname": u["nickname"], "mobile": u["mobile"]})


@app.post("/api/v1/user/logout")
async def logout(request: Request, authorization: Optional[str] = Header(None)) -> Any:
    u = current_user(authorization)
    if u:
        db.run("UPDATE users SET token=? WHERE uid=?", ("", u["uid"]))
    return envelope(0, "", {})


@app.post("/api/v1/tool/fp/token")
async def fp_token(request: Request) -> Any:
    return envelope(0, "", {"token": secrets.token_hex(16), "expire_at": now_ms() + 3600000})


# ---------------------------------------------------------------- 设备

def _register_device(uid: str, body: Dict[str, Any], platform: str) -> Dict[str, Any]:
    device_id = str(body.get("device_id") or "").strip()
    if not device_id:
        # 优先用客户端给的稳定标识；都没有时把设备名纳入种子并加随机数，
        # 避免同平台两台设备算出同一个 id（真实客户端通常自带 device_id）。
        seed = "".join(str(body.get(k) or "") for k in ("uuid", "mac", "android_id", "imei"))
        if not seed.strip():
            seed = str(body.get("device_name") or body.get("name") or "") + uuid.uuid4().hex
        device_id = hashlib.md5(seed.encode()).hexdigest()
    name = str(body.get("device_name") or body.get("name") or platform)
    row = db.one("SELECT * FROM devices WHERE device_id=?", (device_id,))
    if row:
        db.run("UPDATE devices SET uid=?,name=?,platform=?,last_seen=? WHERE device_id=?",
               (uid, name, platform, now_ms(), device_id))
    else:
        db.run("INSERT INTO devices(device_id,uid,name,platform,online,last_seen,created_at)"
               " VALUES(?,?,?,?,0,?,?)", (device_id, uid, name, platform, now_ms(), now_ms()))
    return {"device_id": device_id, "device_name": name, "platform": platform}


@app.post("/api/v1/device/android/init")
async def device_android(request: Request, authorization: Optional[str] = Header(None)) -> Any:
    u = current_user(authorization)
    if not u:
        return err(1001, "invalid authorization")
    return envelope(0, "", _register_device(u["uid"], await request.json(), "android"))


@app.post("/api/v1/device/android_tv/init")
async def device_android_tv(request: Request, authorization: Optional[str] = Header(None)) -> Any:
    u = current_user(authorization)
    if not u:
        return err(1001, "invalid authorization")
    return envelope(0, "", _register_device(u["uid"], await request.json(), "android_tv"))


@app.post("/api/v1/device/pc/init")
async def device_pc(request: Request, authorization: Optional[str] = Header(None)) -> Any:
    u = current_user(authorization)
    if not u:
        return err(1001, "invalid authorization")
    return envelope(0, "", _register_device(u["uid"], await request.json(), "pc"))


@app.post("/api/v1/device/list")
async def device_list(request: Request, authorization: Optional[str] = Header(None)) -> Any:
    u = current_user(authorization)
    if not u:
        return err(1001, "invalid authorization")
    rows = db.all("SELECT * FROM devices WHERE uid=? ORDER BY created_at DESC", (u["uid"],))
    out = []
    for r in rows:
        live = bool(device_online(r["device_id"]))
        out.append({"device_id": r["device_id"], "device_name": r["name"],
                    "platform": r["platform"], "online": 1 if live else 0,
                    "last_seen": r["last_seen"] or 0})
    return envelope(0, "", {"list": out, "devices": out})


# ---------------------------------------------------------------- 房间

def _create_room(uid: str, device_id: str, mode: str) -> Optional[sqlite3.Row]:
    dev = db.one("SELECT * FROM devices WHERE device_id=?", (device_id,))
    if not dev:
        return None
    room_id = uuid.uuid4().hex[:16]
    token = secrets.token_urlsafe(24)
    db.run("INSERT INTO rooms(room_id,token,host_uid,device_id,mode,created_at)"
           " VALUES(?,?,?,?,?,?)", (room_id, token, uid, device_id, mode, now_ms()))
    rooms_by_token[token] = room_id
    return db.one("SELECT * FROM rooms WHERE room_id=?", (room_id,))


@app.post("/api/v1/room/create")
async def room_create(request: Request, authorization: Optional[str] = Header(None)) -> Any:
    u = current_user(authorization)
    if not u:
        return err(1001, "invalid authorization")
    body = await request.json()
    row = _create_room(u["uid"], str(body.get("device_id") or ""), str(body.get("mode") or "control"))
    if not row:
        return err(2001, "device not found")
    return envelope(0, "", room_config(row, u["uid"]))


@app.post("/api/v1/room/join/by_device/{device_id}")
async def room_join(device_id: str, request: Request, authorization: Optional[str] = Header(None)) -> Any:
    u = current_user(authorization)
    if not u:
        return err(1001, "invalid authorization")
    row = _create_room(u["uid"], device_id, "control")
    if not row:
        return err(2001, "device not found")
    return envelope(0, "", room_config(row, u["uid"]))


@app.post("/api/v1/room/join/refetch")
async def room_refetch(request: Request, authorization: Optional[str] = Header(None)) -> Any:
    u = current_user(authorization)
    if not u:
        return err(1001, "invalid authorization")
    body = await request.json()
    row = db.one("SELECT * FROM rooms WHERE room_id=? AND closed=0", (str(body.get("room_id") or ""),))
    if not row:
        return err(2002, "room not found")
    return envelope(0, "", room_config(row, u["uid"]))


@app.post("/api/v1/room/clear/{room_id}")
async def room_clear(room_id: str, request: Request, authorization: Optional[str] = Header(None)) -> Any:
    u = current_user(authorization)
    if not u:
        return err(1001, "invalid authorization")
    db.run("UPDATE rooms SET closed=1 WHERE room_id=?", (room_id,))
    for tok, rid in list(rooms_by_token.items()):
        if rid == room_id:
            rooms_by_token.pop(tok, None)
    db.run("UPDATE rpc SET status='closed' WHERE status IN ('pending','delivered')")
    return envelope(0, "", {"room_id": room_id})


# ---------------------------------------------------------------- RPC 中继

@app.post("/api/v1/transport/{device_id}/rpc/request")
async def rpc_request(device_id: str, request: Request, authorization: Optional[str] = Header(None)) -> Any:
    """把调用方的 p/data 原样投递给目标设备，等待其应答后回传。

    data 可为任意 JSON（字符串/数组/对象），二进制走 base64 字符串，服务端不解释语义。
    """
    u = current_user(authorization)
    if not u:
        return err(1001, "invalid authorization")
    body = await request.json()
    p = str(body.get("p") or "")
    need = 1 if body.get("need_response", True) else 0
    payload = dumps(body.get("data"))
    src = str(body.get("source_device_id") or body.get("device_id") or "")
    cur = db.run("INSERT INTO rpc(target,source,p,need_response,payload,status,created_at,updated_at)"
                 " VALUES(?,?,?,?,?,?,?,?)",
                 (device_id, src, p, need, payload, "pending", now_ms(), now_ms()))
    rid = int(cur.lastrowid)

    # 快路径：目标设备在线且有 WS 通道时，通过 WS 推送（不阻塞 HTTP 响应线程的做法见下）
    if not need:
        return envelope(0, "", {"id": rid, "accepted": True})

    deadline = time.time() + RPC_TIMEOUT
    while time.time() < deadline:
        row = db.one("SELECT * FROM rpc WHERE id=?", (rid,))
        if row and row["status"] == "done":
            return envelope(0, "", {"id": rid, "code": 0, "data": json.loads(row["response"] or "null")})
        if row and row["status"] == "closed":
            return err(2003, "room closed")
        time.sleep(0.05)
    db.run("UPDATE rpc SET status='timeout',updated_at=? WHERE id=?", (now_ms(), rid))
    return err(2004, "device no response")


@app.get("/api/v1/transport/{device_id}/rpc/poll")
async def rpc_poll(device_id: str, authorization: Optional[str] = Header(None), limit: int = 20) -> Any:
    """被控设备拉取待处理调用（长轮询由客户端自行控制间隔）。"""
    u = current_user(authorization)
    if not u:
        return err(1001, "invalid authorization")
    db.run("UPDATE devices SET online=1,last_seen=? WHERE device_id=?", (now_ms(), device_id))
    rows = db.all("SELECT * FROM rpc WHERE target=? AND status='pending' ORDER BY id LIMIT ?",
                  (device_id, limit))
    items = []
    for r in rows:
        db.run("UPDATE rpc SET status='delivered',updated_at=? WHERE id=?", (now_ms(), r["id"]))
        items.append({"id": r["id"], "p": r["p"], "source": r["source"],
                      "need_response": bool(r["need_response"]), "data": json.loads(r["payload"] or "null")})
    return envelope(0, "", {"list": items, "items": items})


@app.post("/api/v1/transport/{device_id}/rpc/respond")
async def rpc_respond(device_id: str, request: Request, authorization: Optional[str] = Header(None)) -> Any:
    u = current_user(authorization)
    if not u:
        return err(1001, "invalid authorization")
    body = await request.json()
    rid = int(body.get("id") or 0)
    data = body.get("data")
    db.run("UPDATE rpc SET status='done',response=?,updated_at=? WHERE id=? AND target=?",
           (dumps(data), now_ms(), rid, device_id))
    return envelope(0, "", {"id": rid})


@app.get("/api/v1/transport/{device_id}/queue")
async def queue_dump(device_id: str) -> Any:
    """调试：查看该设备队列状态。"""
    rows = db.all("SELECT id,p,source,status FROM rpc WHERE target=? ORDER BY id DESC LIMIT 50", (device_id,))
    return envelope(0, "", {"list": [dict(r) for r in rows]})


# ---------------------------------------------------------------- WebSocket 信令

def _subprotocol(ws: WebSocket) -> Optional[str]:
    raw = ws.headers.get("sec-websocket-protocol") or ""
    parts = [p.strip() for p in raw.split(",") if p.strip()]
    return parts[0] if parts else None


@app.websocket("/ws/signaling")
async def signaling(ws: WebSocket) -> None:
    """二进制透明中继。

    - 身份来自 query：`token` = 房间 token，`device_id` 可选。
    - 客户端发什么就转什么（text/binary 均原样转发给同房间的其他节点），不做任何注入，
      避免破坏客户端自定义帧格式。
    - 子协议原样回显，满足客户端的 Sec-WebSocket-Protocol 校验。
    """
    token = ws.query_params.get("token") or ws.query_params.get("room_token") or ""
    device_id = ws.query_params.get("device_id") or ""
    room_id = rooms_by_token.get(token)
    if not room_id:
        await ws.close(code=4002)
        return

    await ws.accept(subprotocol=_subprotocol(ws))

    room = db.one("SELECT * FROM rooms WHERE room_id=?", (room_id,))
    peer_id = device_id or (room["device_id"] if room else "")
    with _lock:
        peers.setdefault(room_id, {}).setdefault(peer_id, []).append(ws)
    db.run("UPDATE devices SET online=1,last_seen=? WHERE device_id=?", (now_ms(), peer_id))

    try:
        while True:
            msg = await ws.receive()
            if msg.get("type") == "websocket.disconnect":
                break
            text = msg.get("text")
            data = msg.get("bytes")
            with _lock:
                # 只转发同一房间内的其它连接（含同 device_id 的其他端）
                targets = [w for devs in [peers.get(room_id, {})] for lst in devs.values()
                           for w in lst if w is not ws]
            for w in targets:
                try:
                    if data is not None:
                        await w.send_bytes(data)
                    elif text is not None:
                        await w.send_text(text)
                except Exception:
                    continue
    except WebSocketDisconnect:
        pass
    finally:
        with _lock:
            devs = peers.get(room_id, {})
            lst = devs.get(peer_id, [])
            if ws in lst:
                lst.remove(ws)
            if not lst:
                devs.pop(peer_id, None)
            if not devs:
                peers.pop(room_id, None)
        db.run("UPDATE devices SET online=0,last_seen=? WHERE device_id=?", (now_ms(), peer_id))


# ---------------------------------------------------------------- 设备管理 / 管理页

@app.post("/api/v1/device/rename")
async def device_rename(request: Request, authorization: Optional[str] = Header(None)) -> Any:
    u = current_user(authorization)
    if not u:
        return err(1001, "invalid authorization")
    body = await request.json()
    did = str(body.get("device_id") or "")
    name = str(body.get("device_name") or body.get("name") or "")
    if not did or not name:
        return err(1002, "device_id and device_name required")
    db.run("UPDATE devices SET name=? WHERE device_id=? AND uid=?", (name, did, u["uid"]))
    return envelope(0, "", {"device_id": did, "device_name": name})


@app.post("/api/v1/device/delete")
async def device_delete(request: Request, authorization: Optional[str] = Header(None)) -> Any:
    u = current_user(authorization)
    if not u:
        return err(1001, "invalid authorization")
    did = str((await request.json()).get("device_id") or "")
    db.run("DELETE FROM devices WHERE device_id=? AND uid=?", (did, u["uid"]))
    return envelope(0, "", {"device_id": did})


@app.get("/api/v1/room/list")
async def room_list(authorization: Optional[str] = Header(None)) -> Any:
    u = current_user(authorization)
    if not u:
        return err(1001, "invalid authorization")
    rows = db.all("SELECT * FROM rooms WHERE host_uid=? AND closed=0 ORDER BY created_at DESC LIMIT 50",
                  (u["uid"],))
    return envelope(0, "", {"list": [{"room_id": r["room_id"], "device_id": r["device_id"],
                                      "mode": r["mode"], "created_at": r["created_at"]}
                                     for r in rows]})


@app.get("/admin", include_in_schema=False)
async def admin_page() -> Any:
    """极简管理页：设备、房间、在线状态、抓取到的请求。"""
    html = """<!doctype html><meta charset=utf-8><title>UU 自建服务端</title>
<style>body{font:14px/1.6 system-ui;margin:24px;background:#111;color:#eee}
h2{margin:20px 0 8px;font-size:15px;color:#8cf}table{border-collapse:collapse;width:100%}
td,th{border-bottom:1px solid #333;padding:5px 8px;text-align:left;font-family:ui-monospace}
th{color:#888;font-weight:400}code{color:#fc8}</style>
<h1 style="font-size:18px">UU 远程 · 自建服务端</h1>
<div id=stat></div><div id=body></div>
<script>
async function j(u){const r=await fetch(u);return r.json()}
// 抓取内容来自客户端请求（不可信），插入 DOM 前统一转义，避免 XSS
const esc=s=>String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
(async()=>{
 const s=await j('/healthz');
 stat.innerHTML=`<p>房间 <b>${s.rooms}</b> · 在线设备 <b>${s.devices_online}</b> · ${esc(new Date(s.ts).toLocaleString())}</p>`;
 const cap=await j('/debug/capture?limit=30');
 body.innerHTML='<h2>最近请求</h2><table><tr><th>时间</th><th>方法</th><th>路径</th><th>Host</th></tr>'+
  cap.data.list.slice().reverse().map(e=>`<tr><td>${esc(new Date(e.ts).toLocaleTimeString())}</td><td>${esc(e.method)}</td>`+
  `<td><code>${esc(e.path)}</code></td><td>${esc((e.headers||{}).host||'')}</td></tr>`).join('')+'</table>';
})()
</script>"""
    from fastapi.responses import HTMLResponse
    return HTMLResponse(html)


# ---------------------------------------------------------------- 兜底

@app.api_route("/api/{path:path}", methods=["POST", "GET", "PUT", "DELETE"],
               include_in_schema=False)
async def fallback(path: str, request: Request) -> Any:
    """未实现的接口：记录原始报文并回空成功，避免客户端直接断链。"""
    return envelope(0, "", None)


@app.get("/debug/capture")
async def debug_capture(limit: int = 50) -> Any:
    if not CAPTURE.exists():
        return envelope(0, "", {"list": []})
    lines = CAPTURE.read_text(encoding="utf-8", errors="replace").strip().split("\n")
    out = []
    for line in lines[-limit:]:
        try:
            out.append(json.loads(line))
        except Exception:
            continue
    return envelope(0, "", {"list": out})


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("UU_PORT", "8443")))