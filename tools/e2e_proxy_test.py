"""端到端验证：经 mitmproxy + 自建 CA，走官方域名完成 REST 与 WebSocket 信令。

覆盖：
1) REST 登录 / 设备注册 / 建房（全部走 https://api.nrd.nie.163.com:443，经 8080 代理）
2) 双端 WebSocket 连接房间信令，A 发帧 → B 收到（证明信令透传链路成立）
"""
from __future__ import annotations

import asyncio
import json
import ssl
import sys
import urllib.request

import websockets

BASE = "https://api.nrd.nie.163.com"
CA = "srv/certs/ca.crt"
PROXY = "http://127.0.0.1:8080"


def api(path: str, body: dict | None = None, token: str | None = None) -> dict:
    ctx = ssl.create_default_context(cafile=CA)
    handler = urllib.request.ProxyHandler({"https": PROXY, "http": PROXY})
    opener = urllib.request.build_opener(
        handler, urllib.request.HTTPSHandler(context=ctx)
    )
    data = json.dumps(body or {}).encode()
    req = urllib.request.Request(
        BASE + path, data=data, method="POST",
        headers={"Content-Type": "application/json",
                 **({"Authorization": f"Bearer {token}"} if token else {})},
    )
    with opener.open(req, timeout=20) as r:
        return json.loads(r.read().decode())


def main() -> int:
    ctx = ssl.create_default_context(cafile=CA)

    async def run() -> None:
        # --- REST ---
        login = api("/api/v1/login/by_mobile", {"mobile": "13700000001"})
        assert login["code"] == 0, login
        tok = login["data"]["token"]
        print("login ok      uid =", login["data"]["uid"])

        init = api("/api/v1/device/android/init", {"device_name": "host-A", "os": "android"}, tok)
        assert init["code"] == 0, init
        dev_a = init["data"]["device_id"]
        print("device-A ok   id  =", dev_a)

        init_b = api("/api/v1/device/android/init", {"device_name": "peer-B", "os": "android"}, tok)
        dev_b = init_b["data"]["device_id"]
        print("device-B ok   id  =", dev_b)

        room = api("/api/v1/room/create", {"device_id": dev_a, "mode": "control"}, tok)
        assert room["code"] == 0, room
        cfg = room["data"]
        rtok = cfg["token"]
        print("room ok       signaling =", cfg["signaling_server"])
        assert cfg["signaling_server"].startswith("wss://api.nrd.nie.163.com"), cfg

        # --- WebSocket 信令：服务端为二进制透明中继，不注入任何帧 ---
        # 真实客户端的信令格式由两端自行协商，服务端只负责按房间转发。
        url = f"wss://api.nrd.nie.163.com/ws/signaling?token={rtok}"
        async with websockets.connect(url + f"&device_id={dev_a}", ssl=ctx, proxy=PROXY,
                                      subprotocols=["uu.v1"]) as wa, \
                   websockets.connect(url + f"&device_id={dev_b}", ssl=ctx, proxy=PROXY) as wb:
            print("ws connected  A subprotocol =", wa.subprotocol)
            assert wa.subprotocol == "uu.v1", wa.subprotocol

            # 文本帧 A→B
            probe = {"kind": "offer", "p": "transport.probe", "data": "aGVsbG8="}
            await wa.send(json.dumps(probe))
            got = json.loads(await asyncio.wait_for(wb.recv(), 10))
            print("ws relay A→B  =", got)
            assert got.get("p") == "transport.probe", got

            # 二进制帧 B→A（模拟客户端私有帧，逐字节比对）
            blob = bytes(range(48))
            await wb.send(blob)
            back = await asyncio.wait_for(wa.recv(), 10)
            assert back == blob, len(back)
            print("ws relay B→A  = binary", len(blob), "bytes OK")

    asyncio.run(run())
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())