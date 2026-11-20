"""轻量远程桌面 Agent（被控端，Windows / macOS / Linux）。

链路：Agent --WSS--> 自建服务端 <--WSS-- 手机 H5 控制页
- 上行：屏幕 JPEG 帧（二进制 WS 帧，前缀 b"FRM1"）
- 下行：输入事件 / 控制指令（JSON 文本帧，p 字段路由）
- 关机：走服务端 RPC 或 WS 指令，30 秒缓冲可撤销，绝不静默执行

运行：
  python agent.py --server https://<host>:8443 --mobile 13800000000 --name MY-PC
  可选 --insecure（自签证书调试）  --fps 15  --quality 75  --width 1920
  画面清晰度/带宽权衡：--width 越大越清晰但流量越大；--quality 建议 60-85

依赖：pip install mss pillow pyautogui websockets httpx
macOS 需在 系统设置→隐私与安全性 授予 屏幕录制 + 辅助功能 权限。
"""
from __future__ import annotations

import argparse
import asyncio
import io
import json
import platform
import ssl
import subprocess
import sys
import time

import httpx
import mss
import websockets
from PIL import Image

SYSTEM = platform.system()  # Windows / Darwin / Linux
FRAME_MAGIC = b"FRM1"


# ---------------------------------------------------------------- 输入注入

def _init_input():
    """按平台初始化输入后端；返回 inject(event) 函数。"""
    import pyautogui
    pyautogui.FAILSAFE = False
    pyautogui.PAUSE = 0
    sw, sh = pyautogui.size()

    def inject(ev: dict) -> None:
        t = ev.get("t")
        # 坐标：控制页发归一化 0..1，映射到真实分辨率
        if "x" in ev and "y" in ev:
            x = int(float(ev["x"]) * sw)
            y = int(float(ev["y"]) * sh)
        if t == "move":
            pyautogui.moveTo(x, y)
        elif t == "down":
            pyautogui.mouseDown(x, y, button=ev.get("btn", "left"))
        elif t == "up":
            pyautogui.mouseUp(x, y, button=ev.get("btn", "left"))
        elif t == "click":
            pyautogui.click(x, y, clicks=2 if ev.get("double") else 1,
                            button=ev.get("btn", "left"))
        elif t == "scroll":
            pyautogui.scroll(int(ev.get("dy", 0)))
        elif t == "key":
            # ev.k: 单键名（pyautogui 命名）；ev.combo: ["ctrl","c"]
            combo = ev.get("combo")
            if combo:
                pyautogui.hotkey(*combo)
            elif ev.get("k"):
                pyautogui.press(ev["k"])
        elif t in ("keydown", "keyup"):
            # 修饰键独立按住/抬起（按住 Shift 点选、按住 Ctrl 滚轮等）
            k = str(ev.get("k", ""))
            if k:
                (pyautogui.keyDown if t == "keydown" else pyautogui.keyUp)(k)
        elif t == "press":
            k = str(ev.get("k", ""))
            if k:
                try:
                    pyautogui.press(k)
                except (KeyError, ValueError):
                    if len(k) == 1:  # pyautogui 不认识的字符退回文本粘贴
                        _paste_text(k)
                    else:
                        raise
        elif t == "text":
            # 中文/任意文本走剪贴板粘贴，避免 typewrite 不支持非 ASCII
            _paste_text(str(ev.get("v", "")))

    return inject, (sw, sh)


def _paste_text(text: str) -> None:
    import pyautogui
    if SYSTEM == "Windows":
        subprocess.run(["powershell", "-NoProfile", "-Command",
                        "Set-Clipboard -Value $input"], input=text.encode("utf-16-le"), check=False)
        pyautogui.hotkey("ctrl", "v")
    elif SYSTEM == "Darwin":
        p = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
        p.communicate(text.encode("utf-8"))
        pyautogui.hotkey("command", "v")
    else:
        pyautogui.typewrite(text)  # Linux 尽力而为


# ---------------------------------------------------------------- 关机（可撤销）

_shutdown_task: asyncio.Task | None = None


def _shutdown_cmd(seconds: int) -> list[str]:
    if SYSTEM == "Windows":
        return ["shutdown", "/s", "/t", str(seconds)]
    if SYSTEM == "Darwin":
        # macOS shutdown 需要 root；无 root 时走 osascript 触发系统关机对话框
        return ["osascript", "-e", 'tell app "System Events" to shut down']
    return ["shutdown", "-h", f"+{max(1, seconds // 60)}"]


def _cancel_cmd() -> list[str]:
    if SYSTEM == "Windows":
        return ["shutdown", "/a"]
    if SYSTEM == "Darwin":
        return []  # osascript 对话框由用户取消
    return ["shutdown", "-c"]


async def handle_shutdown(ev: dict, send_json) -> None:
    """30s 缓冲：先发预告，期间收到 cancel 则中止；到点才真正执行。"""
    global _shutdown_task
    if ev.get("cancel"):
        if _shutdown_task and not _shutdown_task.done():
            _shutdown_task.cancel()
        subprocess.run(_cancel_cmd(), check=False)
        await send_json({"p": "shutdown.state", "state": "cancelled"})
        return

    delay = int(ev.get("delay", 30))

    async def _do() -> None:
        try:
            for remain in range(delay, 0, -1):
                await send_json({"p": "shutdown.state", "state": "pending", "remain": remain})
                await asyncio.sleep(1)
            await send_json({"p": "shutdown.state", "state": "executing"})
            subprocess.run(_shutdown_cmd(0 if SYSTEM != "Windows" else 5), check=False)
        except asyncio.CancelledError:
            await send_json({"p": "shutdown.state", "state": "cancelled"})

    if _shutdown_task and not _shutdown_task.done():
        _shutdown_task.cancel()
    _shutdown_task = asyncio.create_task(_do())


# ---------------------------------------------------------------- 主循环

async def run(args: argparse.Namespace, reuse_device: str | None = None) -> None:
    verify: ssl.SSLContext | bool = True
    if args.insecure:
        verify = ssl.create_default_context()
        verify.check_hostname = False
        verify.verify_mode = ssl.CERT_NONE

    # 稳定指纹：机器名+系统+MAC 派生，重装/改名前保持不变，
    # 服务端按指纹去重，同账号重复登录不产生重复设备。
    import uuid as _uuid
    fp = f"{platform.node()}-{SYSTEM}-{_uuid.getnode():x}"

    async with httpx.AsyncClient(base_url=args.server, verify=verify, timeout=15) as hc:
        if args.token:
            # App 一体化模式：复用控制页登录态，不重新登录（避免顶掉控制页 token）
            tok = args.token
            info = (await hc.post("/api/v1/user/info", json={},
                                  headers={"Authorization": "Bearer " + tok})).json()
            if info.get("code") != 0:
                raise RuntimeError("token 已失效，请在 App 内重新登录")
        else:
            login = (await hc.post("/api/v1/login/by_mobile", json={"mobile": args.mobile})).json()
            assert login["code"] == 0, login
            tok = login["data"]["token"]
        h = {"Authorization": "Bearer " + tok}
        plat = "pc"
        # 重连时带上已知 device_id，即使服务端是旧版也不产生重复设备行。
        init_body = {"device_name": args.name, "uuid": fp, "os": SYSTEM}
        if reuse_device:
            init_body["device_id"] = reuse_device
        init = (await hc.post(f"/api/v1/device/{plat}/init",
                              json=init_body, headers=h)).json()
        assert init["code"] == 0, init
        device_id = init["data"]["device_id"]
        global LAST_DEVICE
        LAST_DEVICE = device_id
        # create 复用该设备最新未关闭房间（服务端语义），断线重连回原房间
        room = (await hc.post("/api/v1/room/create",
                              json={"device_id": device_id, "mode": "control"}, headers=h)).json()
        assert room["code"] == 0, room
        cfg = room["data"]
        print(f"[agent] device={device_id} room={cfg['room_id']}", flush=True)
        print(f"[agent] 手机打开 {args.server}/control 登录同一手机号即可控制", flush=True)

    inject, (sw, sh) = _init_input()
    # 信令地址跟随 --server 实际 scheme（调试时可能是 http/ws）
    ws_base = args.server.rstrip("/").replace("https://", "wss://").replace("http://", "ws://")
    ws_url = ws_base + "/ws/signaling" + f"?token={cfg['token']}&device_id={device_id}"
    ws_kw: dict = {"max_size": 8 * 1024 * 1024}
    if ws_url.startswith("wss://"):
        if args.insecure:
            ws_ssl = ssl.create_default_context()
            ws_ssl.check_hostname = False
            ws_ssl.verify_mode = ssl.CERT_NONE
            ws_kw["ssl"] = ws_ssl
        # 否则用默认校验；ws:// 明文调试不带 ssl 参数

    async with websockets.connect(ws_url, **ws_kw) as ws:
        streaming = asyncio.Event()
        streaming.set()  # 默认推流；控制页可发 pause/resume

        async def send_json(obj: dict) -> None:
            await ws.send(json.dumps(obj, ensure_ascii=False))

        # 运行时画质参数（控制页 stream.config 可动态调，无需重启 Agent）
        stream_cfg = {"fps": args.fps, "quality": args.quality, "width": args.width}

        await send_json({"p": "agent.hello", "name": args.name, "os": SYSTEM,
                         "screen": {"w": sw, "h": sh}, "stream": dict(stream_cfg)})

        async def rx() -> None:
            async for raw in ws:
                if isinstance(raw, bytes):
                    continue  # Agent 不消费对端二进制
                ev = json.loads(raw)
                p = ev.get("p", "")
                if p == "peer.join":
                    # 新控制端进房：重发 hello（对方可能错过首次广播）
                    await send_json({"p": "agent.hello", "name": args.name, "os": SYSTEM,
                                     "screen": {"w": sw, "h": sh}, "stream": dict(stream_cfg)})
                    continue
                try:
                    if p == "input":
                        inject(ev)
                    elif p == "shutdown":
                        await handle_shutdown(ev, send_json)
                    elif p == "stream.pause":
                        streaming.clear()
                    elif p == "stream.resume":
                        streaming.set()
                    elif p == "stream.config":
                        if ev.get("fps"):
                            stream_cfg["fps"] = max(1, min(30, int(ev["fps"])))
                        if ev.get("quality"):
                            stream_cfg["quality"] = max(30, min(90, int(ev["quality"])))
                        if ev.get("width"):
                            stream_cfg["width"] = max(640, min(3840, int(ev["width"])))
                        await send_json({"p": "stream.config.ack", **stream_cfg})
                    elif p == "ping":
                        await send_json({"p": "pong", "ts": ev.get("ts")})
                except Exception as e:  # 单事件失败不断链
                    await send_json({"p": "agent.error", "err": str(e)})

        async def tx() -> None:
            # 截屏+编码放线程（不阻塞输入注入/心跳）；主协程只负责发送。
            # 背压策略：上一帧还没发完就丢弃新帧——永远发最新画面，
            # 避免网络慢时旧帧排队导致延迟越积越高。
            loop = asyncio.get_running_loop()
            frame_q: asyncio.Queue = asyncio.Queue(maxsize=1)
            stop = asyncio.Event()

            def capture_loop() -> None:
                import hashlib
                last_hash = None
                with mss.mss() as sct:
                    mon = sct.monitors[1]
                    while not stop.is_set():
                        t0 = time.monotonic()
                        interval = 1.0 / stream_cfg["fps"]
                        try:
                            shot = sct.grab(mon)
                            img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
                            w = stream_cfg["width"]
                            if img.width > w:
                                img = img.resize((w, max(2, int(img.height * w / img.width))),
                                                 Image.BILINEAR)
                            # 画面没变则不重复编码（省带宽）；但每 2s 保活一帧
                            h = hashlib.md5(img.tobytes()[::997]).digest()
                            now = time.monotonic()
                            if h != last_hash or now - getattr(capture_loop, "_ka", 0) > 2:
                                last_hash = h
                                capture_loop._ka = now
                                buf = io.BytesIO()
                                # subsampling=2 (4:2:0) + 无 optimize：编码最快、体积减半
                                img.save(buf, "JPEG", quality=stream_cfg["quality"],
                                         subsampling=2, optimize=False)
                                # FRM1 + 8字节大端毫秒时戳（控制页据此算单向延迟）
                                ts = int(time.time() * 1000).to_bytes(8, "big")
                                data = FRAME_MAGIC + ts + buf.getvalue()
                                loop.call_soon_threadsafe(_offer, data)
                        except Exception:
                            pass  # 单帧失败跳过，不断流
                        time.sleep(max(0.0, interval - (time.monotonic() - t0)))

            def _offer(data: bytes) -> None:
                capture_loop._last = data
                if frame_q.full():
                    try:
                        frame_q.get_nowait()  # 丢旧帧
                    except asyncio.QueueEmpty:
                        pass
                try:
                    frame_q.put_nowait(data)
                except asyncio.QueueFull:
                    pass

            cap = asyncio.create_task(asyncio.to_thread(capture_loop))
            try:
                while True:
                    if not streaming.is_set():
                        await asyncio.sleep(0.2)
                        continue
                    try:
                        data = await asyncio.wait_for(frame_q.get(), timeout=0.5)
                    except asyncio.TimeoutError:
                        continue
                    await ws.send(data)  # 发不完时 capture 侧自动丢帧
            finally:
                stop.set()
                cap.cancel()

        await asyncio.gather(rx(), tx())


LAST_DEVICE: str | None = None  # 断线重连时复用，避免旧服务端堆重复设备


def main() -> int:
    ap = argparse.ArgumentParser(description="轻量远程桌面 Agent")
    ap.add_argument("--server", required=True, help="https://<host>:8443")
    ap.add_argument("--mobile", help="登录手机号（与控制页一致）")
    ap.add_argument("--token", help="复用已有登录 token（App 一体化模式，不重复登录）")
    ap.add_argument("--name", default=platform.node(), help="设备名")
    ap.add_argument("--fps", type=int, default=15)
    ap.add_argument("--quality", type=int, default=75, help="JPEG 质量 30-90")
    ap.add_argument("--width", type=int, default=1920, help="帧最大宽度（越大越清晰）")
    ap.add_argument("--insecure", action="store_true", help="跳过证书校验（自签调试）")
    args = ap.parse_args()
    if not args.mobile and not args.token:
        ap.error("需要 --mobile 或 --token 之一")
    while True:
        try:
            asyncio.run(run(args, reuse_device=LAST_DEVICE))
        except KeyboardInterrupt:
            print("\n[agent] bye")
            return 0
        except Exception as e:
            print(f"[agent] 断链: {e}，5s 后重连", file=sys.stderr, flush=True)
            time.sleep(5)


if __name__ == "__main__":
    sys.exit(main())