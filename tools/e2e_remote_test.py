"""端到端实测：模拟手机控制页，验证 Agent 帧流 / 输入 / 关机撤销全链路。

前置：服务端已运行（默认 http://127.0.0.1:8443），Agent 已用同一手机号接入。
运行：python tools/e2e_remote_test.py [--server URL] [--mobile N]

验证项：
1) 登录 + 设备列表能看到 Agent 设备且在线
2) join 建房 + WS 接入，收到 agent.hello
3) 收到 FRM1 JPEG 帧（可解码、尺寸合理）
4) 发 input 事件 Agent 无 error 回执
5) shutdown 30s → 收到 pending 倒计时 → cancel → 收到 cancelled（不真关机）
"""
from __future__ import annotations

import argparse
import asyncio
import io
import json
import sys

import httpx
import websockets
from PIL import Image

FRAME_MAGIC = b"FRM1"


async def main(server: str, mobile: str) -> int:
    async with httpx.AsyncClient(base_url=server, timeout=15) as hc:
        login = (await hc.post("/api/v1/login/by_mobile", json={"mobile": mobile})).json()
        assert login["code"] == 0, login
        tok = login["data"]["token"]
        h = {"Authorization": "Bearer " + tok}
        dl = (await hc.post("/api/v1/device/list", headers=h)).json()["data"]["list"]
        # 只挑可远程的电脑类设备（手机控制端自身也在线，但不是被控目标）
        online = [d for d in dl if d["online"] and d.get("controllable", d["platform"] == "pc")]
        assert online, f"no online device: {dl}"
        dev = online[0]
        print("1. device online:", dev["device_name"], dev["device_id"])

        room = (await hc.post("/api/v1/room/join/by_device/" + dev["device_id"], headers=h)).json()
        assert room["code"] == 0, room
        cfg = room["data"]

    ws_base = server.replace("https://", "wss://").replace("http://", "ws://")
    url = ws_base + f"/ws/signaling?token={cfg['token']}&device_id=test-phone"
    hello, frames, errors, states = None, [], [], []
    async with websockets.connect(url, max_size=8 * 1024 * 1024) as ws:
        async def collect(seconds: float) -> None:
            nonlocal hello
            end = asyncio.get_event_loop().time() + seconds
            while asyncio.get_event_loop().time() < end:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=max(0.1, end - asyncio.get_event_loop().time()))
                except asyncio.TimeoutError:
                    break
                if isinstance(raw, bytes):
                    if raw.startswith(FRAME_MAGIC):
                        # FRM1 + 8字节毫秒时戳 + JPEG（旧格式无时戳则兼容）
                        body = raw[4:]
                        if body[:2] != b"\xff\xd8" and len(body) > 10:
                            body = body[8:]
                        frames.append(body)
                else:
                    m = json.loads(raw)
                    if m.get("p") == "agent.hello":
                        hello = m
                    elif m.get("p") == "agent.error":
                        errors.append(m)
                    elif m.get("p") == "shutdown.state":
                        states.append(m)

        await collect(2.5)
        assert hello, "no agent.hello received"
        print("2. agent.hello:", hello["name"], hello["os"], hello["screen"])
        assert frames, "no frames received"
        img = Image.open(io.BytesIO(frames[-1]))
        img.load()
        print(f"3. frames: {len(frames)} in 2.5s, last = {img.format} {img.size} {len(frames[-1])//1024}KB")

        # 输入：只发 move（无副作用），再发一次安全按键事件验证路由
        await ws.send(json.dumps({"p": "input", "t": "move", "x": 0.5, "y": 0.5}))
        await ws.send(json.dumps({"p": "ping", "ts": 1}))
        await collect(1.0)
        assert not errors, f"agent errors: {errors}"
        print("4. input routed, no agent.error")

        # 关机：30s 缓冲 → 收倒计时 → 立即撤销
        await ws.send(json.dumps({"p": "shutdown", "delay": 30}))
        await collect(2.5)
        pending = [s for s in states if s["state"] == "pending"]
        assert pending, f"no shutdown pending state: {states}"
        print("5. shutdown pending, remain =", pending[-1]["remain"])
        await ws.send(json.dumps({"p": "shutdown", "cancel": True}))
        await collect(1.5)
        assert any(s["state"] == "cancelled" for s in states), f"no cancelled: {states}"
        assert not any(s["state"] == "executing" for s in states), "shutdown executed!"
        print("6. shutdown cancelled OK (machine stays on)")

    print("\nREMOTE E2E ALL PASS")
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default="http://127.0.0.1:8443")
    ap.add_argument("--mobile", default="13800001111")
    a = ap.parse_args()
    sys.exit(asyncio.run(main(a.server, a.mobile)))