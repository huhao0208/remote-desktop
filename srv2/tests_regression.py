"""回归测试：针对本轮修复的 P0/P1/P2 缺陷。

覆盖：
R1  服务重启后（内存映射清空）WS 仍可用旧房间 token 连接（DB 回退）
R2  refetch 回填映射 + 只能 refetch 自己的房间
R3  RPC 等待期间事件循环不被阻塞（其它请求即时响应）
R4  room/clear 只关闭本房间 RPC，不误杀其它房间在途指令
R5  logout 后旧 token 失效；多用户登出后空 Bearer 不放行
R6  越权防护：不能给他人设备建房 / 下发 RPC / poll / respond
R7  device_id 冲突不抢占他人设备
运行：python tests_regression.py
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import tempfile
import threading
import time

TMP = tempfile.mkdtemp(prefix="uu-reg-")
os.environ["UU_DATA_DIR"] = TMP
os.environ["UU_PUBLIC_BASE"] = "https://api.nrd.nie.163.com"
os.environ["UU_WS_BASE"] = "wss://api.nrd.nie.163.com"
os.environ["UU_RPC_TIMEOUT"] = "5"

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


def login(c: TestClient, mobile: str) -> dict:
    d = c.post("/api/v1/login/by_mobile", json={"mobile": mobile}).json()["data"]
    return {"h": {"Authorization": "Bearer " + d["token"]}, **d}


def main() -> int:
    c = TestClient(server.app)
    a = login(c, "13900000001")
    b = login(c, "13900000002")

    dev_a = c.post("/api/v1/device/pc/init", json={"device_name": "A-PC", "uuid": "a-1"},
                   headers=a["h"]).json()["data"]["device_id"]
    dev_a2 = c.post("/api/v1/device/android/init", json={"device_name": "A-PH", "uuid": "a-2"},
                    headers=a["h"]).json()["data"]["device_id"]
    dev_b = c.post("/api/v1/device/pc/init", json={"device_name": "B-PC", "uuid": "b-1"},
                   headers=b["h"]).json()["data"]["device_id"]

    # ---- R1: 模拟重启（清空全部内存态），旧 token 仍可连 WS ----
    room = c.post("/api/v1/room/create", json={"device_id": dev_a}, headers=a["h"]).json()["data"]
    server.rooms_by_token.clear()
    server.peers.clear()
    with c.websocket_connect("/ws/signaling?token=%s&device_id=%s" % (room["token"], dev_a)) as w:
        w.send_text("ping-after-restart")  # 单连接无对端，能收发即证明鉴权通过
    check("R1 ws works after restart", room["token"] in server.rooms_by_token)

    # ---- R2: refetch 回填映射；他人房间不可 refetch ----
    server.rooms_by_token.clear()
    rf = c.post("/api/v1/room/join/refetch", json={"room_id": room["room_id"]}, headers=a["h"]).json()
    check("R2 refetch restores map", rf["code"] == 0 and room["token"] in server.rooms_by_token, rf)
    rf_b = c.post("/api/v1/room/join/refetch", json={"room_id": room["room_id"]}, headers=b["h"]).json()
    check("R2 refetch foreign denied", rf_b["code"] == 2002, rf_b)

    # ---- R3: RPC 阻塞等待期间，其它 HTTP 请求必须即时响应 ----
    result = {}

    def caller() -> None:
        result["resp"] = c.post("/api/v1/transport/%s/rpc/request" % dev_a2,
                                json={"p": "slow.call", "need_response": True}, headers=a["h"]).json()

    t = threading.Thread(target=caller)
    t.start()
    time.sleep(0.3)  # 确保 caller 已进入等待循环
    t0 = time.monotonic()
    hz = c.get("/healthz").json()
    dt = time.monotonic() - t0
    check("R3 loop not blocked", hz["ok"] and dt < 1.0, "healthz took %.2fs" % dt)
    items = c.get("/api/v1/transport/%s/rpc/poll" % dev_a2, headers=a["h"]).json()["data"]["list"]
    c.post("/api/v1/transport/%s/rpc/respond" % dev_a2,
           json={"id": items[0]["id"], "data": {"ok": 1}}, headers=a["h"])
    t.join(10)
    check("R3 rpc still completes", (result.get("resp") or {}).get("code") == 0, result.get("resp"))

    # ---- R4: clear 房间只杀本房间 RPC ----
    room_x = c.post("/api/v1/room/create", json={"device_id": dev_a}, headers=a["h"]).json()["data"]
    room_y = c.post("/api/v1/room/create", json={"device_id": dev_a2}, headers=a["h"]).json()["data"]
    rx = c.post("/api/v1/transport/%s/rpc/request" % dev_a,
                json={"p": "x", "need_response": False, "room_id": room_x["room_id"]},
                headers=a["h"]).json()
    ry = c.post("/api/v1/transport/%s/rpc/request" % dev_a2,
                json={"p": "y", "need_response": False, "room_id": room_y["room_id"]},
                headers=a["h"]).json()
    c.post("/api/v1/room/clear/" + room_x["room_id"], headers=a["h"])
    sx = server.db.one("SELECT status FROM rpc WHERE id=?", (rx["data"]["id"],))["status"]
    sy = server.db.one("SELECT status FROM rpc WHERE id=?", (ry["data"]["id"],))["status"]
    check("R4 clear scoped to room", sx == "closed" and sy == "pending", (sx, sy))
    cl_b = c.post("/api/v1/room/clear/" + room_y["room_id"], headers=b["h"]).json()
    check("R4 clear foreign denied", cl_b["code"] == 2002, cl_b)

    # ---- R5: logout 语义 ----
    tmp_u = login(c, "13900000003")
    c.post("/api/v1/user/logout", headers=tmp_u["h"])
    gone = c.post("/api/v1/user/info", headers=tmp_u["h"]).json()
    check("R5 old token revoked", gone["code"] == 1001, gone)
    tmp_u2 = login(c, "13900000004")
    c.post("/api/v1/user/logout", headers=tmp_u2["h"])
    empty = c.post("/api/v1/user/info", headers={"Authorization": "Bearer "}).json()
    empty2 = c.post("/api/v1/user/info", headers={"Authorization": ""}).json()
    check("R5 empty bearer rejected", empty["code"] == 1001 and empty2["code"] == 1001, (empty, empty2))

    # ---- R6: 越权防护 ----
    join_b = c.post("/api/v1/room/join/by_device/" + dev_a, headers=b["h"]).json()
    check("R6 join foreign device denied", join_b["code"] == 2001, join_b)
    rpc_b = c.post("/api/v1/transport/%s/rpc/request" % dev_a,
                   json={"p": "evil", "need_response": False}, headers=b["h"]).json()
    check("R6 rpc foreign denied", rpc_b["code"] == 2001, rpc_b)
    poll_b = c.get("/api/v1/transport/%s/rpc/poll" % dev_a, headers=b["h"]).json()
    check("R6 poll foreign denied", poll_b["code"] == 2001, poll_b)
    resp_b = c.post("/api/v1/transport/%s/rpc/respond" % dev_a,
                    json={"id": 1, "data": None}, headers=b["h"]).json()
    check("R6 respond foreign denied", resp_b["code"] == 2001, resp_b)

    # ---- R7: device_id 冲突不抢占 ----
    steal = c.post("/api/v1/device/pc/init",
                   json={"device_id": dev_a, "device_name": "HACK"}, headers=b["h"]).json()
    check("R7 no device takeover", steal["data"]["device_id"] != dev_a, steal)
    owner = server.db.one("SELECT uid,name FROM devices WHERE device_id=?", (dev_a,))
    check("R7 owner intact", owner["uid"] == a["uid"] and owner["name"] == "A-PC", dict(owner))

    # ---- R8: 多端共存登录不顶号 ----
    m1 = c.post("/api/v1/login/by_mobile", json={"mobile": "13900008888"}).json()["data"]
    m2 = c.post("/api/v1/login/by_mobile", json={"mobile": "13900008888"}).json()["data"]
    check("R8 token coexist", m1["token"] == m2["token"] and m1["uid"] == m2["uid"], (m1, m2))
    still = c.post("/api/v1/user/info", headers={"Authorization": "Bearer " + m1["token"]}).json()
    check("R8 old token alive", still["code"] == 0, still)

    # ---- R9: +86 前缀归一化到同一账号 ----
    p86 = c.post("/api/v1/login/by_mobile", json={"mobile": "+86 139-0000-8888"}).json()["data"]
    check("R9 mobile normalized", p86["uid"] == m1["uid"], (p86, m1))

    # ---- R10: 登录携带指纹注册本机 + 指纹去重 ----
    lg = c.post("/api/v1/login/by_mobile", json={
        "mobile": "13900008888", "register_device": 1, "uuid": "fp-phone-1",
        "device_name": "本机·手机", "platform": "mobile"}).json()["data"]
    check("R10 login registers self", lg.get("device", {}).get("platform") == "mobile", lg)
    lg2 = c.post("/api/v1/login/by_mobile", json={
        "mobile": "13900008888", "register_device": 1, "uuid": "fp-phone-1",
        "device_name": "本机·手机", "platform": "mobile"}).json()["data"]
    check("R10 fingerprint dedupe", lg2["device"]["device_id"] == lg["device"]["device_id"], (lg, lg2))
    dl = c.post("/api/v1/device/list", json={"device_id": lg["device"]["device_id"]},
                headers={"Authorization": "Bearer " + lg["token"]}).json()["data"]["list"]
    mine = [d for d in dl if d["device_id"] == lg["device"]["device_id"]]
    check("R10 is_self flagged", mine and mine[0]["is_self"] == 1 and mine[0]["controllable"] == 0, dl)

    # ---- R11: create 默认复用房间，mode=new 才新建 ----
    hh = {"Authorization": "Bearer " + m1["token"]}
    pcx = c.post("/api/v1/device/pc/init", json={"device_name": "X-PC", "uuid": "fp-x"}, headers=hh).json()["data"]
    r_a = c.post("/api/v1/room/create", json={"device_id": pcx["device_id"]}, headers=hh).json()["data"]
    r_b = c.post("/api/v1/room/create", json={"device_id": pcx["device_id"]}, headers=hh).json()["data"]
    check("R11 create reuses room", r_a["room_id"] == r_b["room_id"], (r_a, r_b))
    r_c = c.post("/api/v1/room/create", json={"device_id": pcx["device_id"], "mode": "new"}, headers=hh).json()["data"]
    check("R11 mode new isolates", r_c["room_id"] != r_a["room_id"], (r_a, r_c))

    print("\n%d regression checks PASSED" % PASS)
    return 0


if __name__ == "__main__":
    sys.exit(main())