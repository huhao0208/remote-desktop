"""服务端完整功能测试（不依赖网络、不依赖真实客户端）。

覆盖：鉴权 / 设备注册与在线态 / 房间配置字段对齐 / RPC 双向中继（轮询 + 阻塞等待）/
WebSocket 二进制透明转发与子协议回显 / 未实现接口兜底 / TURN 短期凭据算法 / 请求抓取。
运行：python tests.py
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import sys
import tempfile
import threading
import time

TMP = tempfile.mkdtemp(prefix="uu-test-")
os.environ["UU_DATA_DIR"] = TMP
os.environ["UU_PUBLIC_BASE"] = "https://api.nrd.nie.163.com"
os.environ["UU_WS_BASE"] = "wss://api.nrd.nie.163.com"
os.environ["UU_STUN_URLS"] = "stun:api.nrd.nie.163.com:3478"
os.environ["UU_TURN_URLS"] = "turn:api.nrd.nie.163.com:3478?transport=udp"
os.environ["UU_TURN_SECRET"] = "testsecret123"
os.environ["UU_TURN_TTL"] = "600"
os.environ["UU_RPC_TIMEOUT"] = "10"

from fastapi.testclient import TestClient  # noqa: E402

import server  # noqa: E402

PASS = 0


def check(name: str, cond: bool, detail: object = "") -> None:
    global PASS
    if not cond:
        print("FAIL  %s  %s" % (name, detail))
        sys.exit(1)
    PASS += 1
    print("ok    %s" % name)


def main() -> int:
    c = TestClient(server.app)

    # 1. 健康检查
    r = c.get("/healthz").json()
    check("healthz", r["ok"] is True, r)

    # 2. 登录（同号二次登录应复用 uid，并换发 token）
    l1 = c.post("/api/v1/login/by_mobile", json={"mobile": "13800000001"}).json()
    check("login envelope", l1["code"] == 0 and l1["data"]["token"], l1)
    tok = l1["data"]["token"]
    uid = l1["data"]["uid"]
    l2 = c.post("/api/v1/login/by_mobile", json={"mobile": "13800000001"}).json()
    check("login uid stable", l2["data"]["uid"] == uid and l2["data"]["token"] != tok,
          (uid, l2["data"]["uid"]))
    tok = l2["data"]["token"]
    h = {"Authorization": "Bearer " + tok}

    # 3. 鉴权失败
    bad = c.post("/api/v1/device/list", headers={"Authorization": "Bearer nope"}).json()
    check("auth rejected", bad["code"] == 1001, bad)

    # 4. 设备注册（电脑 + 手机）
    pc = c.post("/api/v1/device/pc/init", json={"device_name": "MY-PC", "uuid": "pc-1"},
                headers=h).json()
    ph = c.post("/api/v1/device/android/init", json={"device_name": "MY-PHONE", "uuid": "ph-1"},
                headers=h).json()
    check("pc registered", bool(pc["data"]["device_id"]), pc)
    check("phone registered", bool(ph["data"]["device_id"]), ph)
    pc_id, ph_id = pc["data"]["device_id"], ph["data"]["device_id"]
    check("device ids differ", pc_id != ph_id)

    # 5. 设备列表
    dl = c.post("/api/v1/device/list", headers=h).json()
    ids = [d["device_id"] for d in dl["data"]["list"]]
    check("device list has both", pc_id in ids and ph_id in ids, ids)

    # 6. 房间配置字段与 RoomConfig 对齐
    room = c.post("/api/v1/room/create", json={"device_id": pc_id}, headers=h).json()
    check("room created", room["code"] == 0, room)
    cfg = room["data"]
    need_keys = ["signaling_server", "token", "signaling_list", "ws_connect_timeout_ms",
                 "streamer_retry_delta_ms", "max_reconnect_delta", "report_token", "report_url",
                 "report_server_address", "international_connect", "sni_required_signaling_list",
                 "streamer_config", "room_id", "ice_servers"]
    missing = [k for k in need_keys if k not in cfg]
    check("room config keys", not missing, missing)
    check("signaling url", cfg["signaling_server"] == "wss://api.nrd.nie.163.com/ws/signaling",
          cfg["signaling_server"])

    # 7. TURN 短时效凭据（coturn use-auth-secret 算法）
    turn = cfg["ice_servers"]["turn"][0]
    expect = base64.b64encode(
        hmac.new(b"testsecret123", turn["username"].encode(), hashlib.sha1).digest()).decode()
    check("turn credential hmac", turn["credential"] == expect, (turn, expect))
    check("turn username has expiry", int(turn["username"].split(":")[0]) > time.time())
    sc = json.loads(cfg["streamer_config"])
    check("ice policy direct-first", sc["ice_transport_policy"] == "all", sc)

    # 8. RPC：调用方阻塞等待，被控端轮询取任务并回包
    result = {}

    def caller() -> None:
        result["resp"] = c.post("/api/v1/transport/%s/rpc/request" % ph_id,
                                json={"p": "terminal.open", "need_response": True,
                                      "data": {"shell": "powershell"}}, headers=h).json()

    t = threading.Thread(target=caller)
    t.start()
    time.sleep(0.4)
    polled = c.get("/api/v1/transport/%s/rpc/poll" % ph_id, headers=h).json()
    items = polled["data"]["list"]
    check("rpc delivered by poll", len(items) == 1 and items[0]["p"] == "terminal.open", polled)
    check("rpc payload intact", items[0]["data"] == {"shell": "powershell"}, items[0])
    rid = items[0]["id"]
    c.post("/api/v1/transport/%s/rpc/respond" % ph_id,
           json={"id": rid, "data": {"session": 42, "ok": True}}, headers=h)
    t.join(15)
    resp = result.get("resp") or {}
    check("rpc response returned", resp.get("code") == 0 and
          resp["data"]["data"] == {"session": 42, "ok": True}, resp)

    # 9. RPC 无应答超时
    result.clear()

    def caller2() -> None:
        result["resp"] = c.post("/api/v1/transport/%s/rpc/request" % ph_id,
                                json={"p": "noop", "need_response": True}, headers=h).json()

    t2 = threading.Thread(target=caller2)
    t2.start()
    t2.join(20)
    check("rpc timeout code", (result.get("resp") or {}).get("code") == 2004, result.get("resp"))

    # 10. WebSocket 二进制透明转发 + 子协议回显
    room2 = c.post("/api/v1/room/create", json={"device_id": pc_id}, headers=h).json()["data"]
    rtok = room2["token"]
    url = "/ws/signaling?token=%s" % rtok
    c2 = TestClient(server.app)
    with c.websocket_connect(url + "&device_id=" + pc_id,
                             subprotocols=["uu.v1"]) as wa:
        check("ws subprotocol echo", wa.accepted_subprotocol == "uu.v1", wa.accepted_subprotocol)
        with c2.websocket_connect(url + "&device_id=" + ph_id) as wb:
            blob = bytes(range(32))
            wa.send_bytes(blob)
            got = wb.receive_bytes()
            check("ws binary relay", got == blob, got)
            wb.send_text("plain-text-frame")
            check("ws text relay", wa.receive_text() == "plain-text-frame")

    # 11. 未实现接口兜底 + 抓取
    unknown = c.post("/api/v1/some/unimplemented", json={"x": 1},
                     headers={"X-Param-PLAT": "android"}).json()
    check("unknown endpoint benign", unknown["code"] == 0, unknown)
    cap = c.get("/debug/capture?limit=5").json()
    paths = [e["path"] for e in cap["data"]["list"]]
    check("capture recorded unknown", "/api/v1/some/unimplemented" in paths, paths)

    # 12. 房间隔离：不同房间的连接互不可见；坏 token 直接拒绝
    room3 = c.post("/api/v1/room/create", json={"device_id": pc_id}, headers=h).json()["data"]
    with c.websocket_connect("/ws/signaling?token=%s&device_id=%s" % (rtok, pc_id)) as _w1:
        with c2.websocket_connect("/ws/signaling?token=%s&device_id=%s" % (room3["token"], pc_id)) as _w2:
            r1 = server.peers.get(room2["room_id"], {})
            r3 = server.peers.get(room3["room_id"], {})
            check("rooms isolated", set(r1) == {pc_id} and set(r3) == {pc_id} and
                  room2["room_id"] != room3["room_id"], (r1, r3))
    bad_tok_ok = False
    try:
        with c.websocket_connect("/ws/signaling?token=not-a-token") as _w:
            pass
    except Exception:
        bad_tok_ok = True
    check("ws rejects bad token", bad_tok_ok)

    # 13. 设备重命名 / 删除 / 房间列表 / 管理页
    rn = c.post("/api/v1/device/rename", json={"device_id": pc_id, "device_name": "STUDIO-PC"},
                headers=h).json()
    check("device renamed", rn["data"]["device_name"] == "STUDIO-PC", rn)
    dl2 = c.post("/api/v1/device/list", headers=h).json()
    check("rename visible", any(d["device_name"] == "STUDIO-PC" for d in dl2["data"]["list"]))
    rl = c.get("/api/v1/room/list", headers=h).json()
    check("room list works", rl["code"] == 0 and isinstance(rl["data"]["list"], list), rl)
    adm = c.get("/admin")
    check("admin page", adm.status_code == 200 and "UU 远程" in adm.text, adm.status_code)
    de = c.post("/api/v1/device/delete", json={"device_id": ph_id}, headers=h).json()
    check("device deleted", de["code"] == 0, de)
    dl3 = c.post("/api/v1/device/list", headers=h).json()
    check("delete visible", ph_id not in [d["device_id"] for d in dl3["data"]["list"]])

    # 13. 房间清理
    cl = c.post("/api/v1/room/clear/" + room2["room_id"], headers=h).json()
    check("room cleared", cl["code"] == 0, cl)
    stale = c.get(url).json() if False else None  # WS 关闭后 token 失效，见下
    r = c.post("/api/v1/room/join/refetch", json={"room_id": room2["room_id"]}, headers=h).json()
    check("cleared room not refetchable", r["code"] == 2002, r)

    print("\n%d checks PASSED" % PASS)
    return 0


if __name__ == "__main__":
    sys.exit(main())