"""键盘链路探针：模拟 Windows 物理键盘控 Mac 的新协议事件，检查 Agent 是否报错。"""
import asyncio
import json
import sys

import httpx
import websockets

SERVER = sys.argv[1] if len(sys.argv) > 1 else "https://47-251-105-202.sslip.io:8444"
MOBILE = sys.argv[2] if len(sys.argv) > 2 else "13800001111"


async def main() -> None:
    async with httpx.AsyncClient(base_url=SERVER, timeout=15) as hc:
        tok = (await hc.post("/api/v1/login/by_mobile",
                             json={"mobile": MOBILE})).json()["data"]["token"]
        h = {"Authorization": "Bearer " + tok}
        dl = (await hc.post("/api/v1/device/list", headers=h)).json()["data"]["list"]
        dev = [d for d in dl if d.get("controllable") and d["online"]][0]
        room = (await hc.post(f"/api/v1/room/join/by_device/{dev['device_id']}",
                              headers=h)).json()["data"]
    ws_base = SERVER.replace("http", "ws", 1)
    url = f"{ws_base}/ws/signaling?token={room['token']}&device_id=probe-kbd"
    errs = []
    hello = None
    events = [
        {"p": "input", "t": "keydown", "k": "command"},
        {"p": "input", "t": "press", "k": "a"},
        {"p": "input", "t": "keyup", "k": "command"},
        {"p": "input", "t": "press", "k": "esc"},
        {"p": "input", "t": "keydown", "k": "shift"},
        {"p": "input", "t": "keyup", "k": "shift"},
        {"p": "input", "t": "key", "combo": ["command", "c"]},
        {"p": "input", "t": "keydown", "k": "option"},
        {"p": "input", "t": "keyup", "k": "option"},
        {"p": "input", "t": "text", "v": "远程键盘测试OK"},
        {"p": "input", "t": "key", "combo": ["command", "a"]},
        {"p": "input", "t": "press", "k": "backspace"},
        {"p": "input", "t": "press", "k": "esc"},
    ]
    async with websockets.connect(url, max_size=8 * 1024 * 1024) as ws:
        for ev in events:
            await ws.send(json.dumps(ev))
            await asyncio.sleep(0.2)
        try:
            while True:
                raw = await asyncio.wait_for(ws.recv(), timeout=3)
                if isinstance(raw, str):
                    m = json.loads(raw)
                    if m.get("p") == "agent.error":
                        errs.append(m.get("err"))
                    if m.get("p") == "agent.hello":
                        hello = m.get("os")
        except asyncio.TimeoutError:
            pass
    print("被控OS:", hello, "| 发送", len(events), "个键盘事件 | agent.error:",
          errs if errs else "无（全部接受执行）")
    sys.exit(1 if errs else 0)


asyncio.run(main())
