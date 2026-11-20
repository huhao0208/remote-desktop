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
import hashlib
import io
import json
import os
import platform
import re
import ssl
import subprocess
import sys
import time
import uuid
from pathlib import Path

import httpx
import mss
import websockets
from PIL import Image

try:  # 脚本直跑（python agent/agent.py）与包内导入（import agent.agent）都要能用
    from ._version import VERSION as AGENT_VERSION
    from .clipboard_sync import ClipboardSync
    from .screens import grab_screencapture, list_monitors
except ImportError:
    from _version import VERSION as AGENT_VERSION
    from clipboard_sync import ClipboardSync
    from screens import grab_screencapture, list_monitors

SYSTEM = platform.system()  # Windows / Darwin / Linux
FRAME_MAGIC = b"FRM1"

# 最近一次收发报文的时间（秒）。自更新靠它判断「现在有没有人在用」——
# 远控进行中重启 agent 会直接断链，所以只在空闲时替换。
LAST_ACTIVITY = 0.0


def mark_activity() -> None:
    global LAST_ACTIVITY
    LAST_ACTIVITY = time.time()


def is_busy(window: float = 120.0) -> bool:
    """两分钟内有任何收发，就认为正在被使用。"""
    return time.time() - LAST_ACTIVITY < window


def _new_mss():
    """mss 10 起 mss.mss() 被弃用（会往日志里刷 DeprecationWarning）。"""
    return mss.MSS() if hasattr(mss, "MSS") else mss.mss()


# ---------------------------------------------------------------- 设备身份

def _device_id_path():
    """device_id 落盘位置：~/.uu-agent/device_id（Windows 在 %APPDATA%\\uu-agent）。"""
    if SYSTEM == "Windows":
        base = os.environ.get("APPDATA") or os.path.expanduser("~")
        return Path(base) / "uu-agent" / "device_id"
    return Path(os.path.expanduser("~")) / ".uu-agent" / "device_id"


def _valid_device_id(s: str) -> bool:
    return bool(re.fullmatch(r"[0-9A-Za-z_-]{8,64}", (s or "").strip()))


def resolve_device_id(arg_id: str | None, new_device: bool, fp: str) -> tuple[str, str]:
    """算出本机稳定 device_id，返回 (id, 来源)。

    优先级：`--device-id` > 持久化文件 > 机器指纹派生 > 随机。
    必须跨进程稳定：服务端按 device_id 去重，每次换 id 就会在用户设备列表里堆一条。
    """
    path = _device_id_path()
    if arg_id and _valid_device_id(arg_id):
        did = arg_id.strip()
        _save_device_id(path, did)
        print(f"[agent] 使用 --device-id 指定设备 id={did}", flush=True)
        return did, "arg"

    if not new_device:
        try:
            if path.exists():
                did = path.read_text(encoding="utf-8").strip()
                if _valid_device_id(did):
                    print(f"[agent] 复用设备 id={did}（如需重新注册请加 --new-device）", flush=True)
                    return did, "file"
        except Exception as e:
            print(f"[agent] 读取 {path} 失败（{e}），改用派生 id", flush=True)

    if new_device:
        did = uuid.uuid4().hex
        print(f"[agent] --new-device：注册新设备 id={did}", flush=True)
    else:
        did = hashlib.md5(f"uu-agent:{fp}".encode()).hexdigest()
        print(f"[agent] 按机器指纹派生设备 id={did}", flush=True)
    if _save_device_id(path, did):
        print(f"[agent] 设备 id 已写入 {path}（下次启动复用）", flush=True)
    return did, "new"


def _save_device_id(path, did: str) -> bool:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(did + "\n", encoding="utf-8")
        return True
    except Exception as e:
        print(f"[agent] 写 {path} 失败（{e}），本次仍用该 id 但不持久", flush=True)
        return False


# ---------------------------------------------------------------- 输入注入

# 协议里的修饰键名（cmd/command/meta/super/win/winleft...）归一到 pyautogui 键名
_PYAGUI_MODS = {"shift", "ctrl", "alt", "command", "win", "winleft", "winright", "super"}


def _norm_key(k: str) -> str:
    low = k.strip().lower()
    if low in ("cmd", "command", "meta", "super", "win", "windows", "winleft", "winright"):
        if SYSTEM == "Darwin":  # 控制页可能发 winleft，mac 上是 Command
            return "command"
        if SYSTEM == "Windows":
            return "winright" if low == "winright" else "winleft"
        return "super"
    if low in ("ctrl", "control"):
        return "ctrl"
    if low in ("alt", "option"):
        return "alt"
    if low == "shift":
        return "shift"
    return k


def _init_input():
    """按平台初始化输入后端；返回 (inject, (w,h), release_all)。

    修饰键状态机（协议 v2 §4）：`keydown/keyup` 只对 shift/ctrl/alt/cmd 保持
    按住（远端按 Shift 多选、Ctrl+滚轮都靠这个）；其它键一律原子按下+抬起。
    `release_all` 用于 WS 断开/失焦，避免远端卡住 Shift。
    """
    import pyautogui
    pyautogui.FAILSAFE = False
    pyautogui.PAUSE = 0
    sw, sh = pyautogui.size()
    pressed: set[str] = set()  # 当前被按住的修饰键（pyautogui 键名）

    def _hold(mods) -> list[str]:
        """按下尚未按住的修饰键，返回本次临时按下的（动作结束要松开）。"""
        held: list[str] = []
        for m in mods or ():
            key = _norm_key(str(m))
            if key in _PYAGUI_MODS and key not in pressed:
                try:
                    pyautogui.keyDown(key)
                except Exception:  # 平台不认这个键名（如 macOS 的 winleft）
                    continue
                pressed.add(key)
                held.append(key)
        return held

    def _release(keys: list[str]) -> None:
        for key in keys:
            try:
                pyautogui.keyUp(key)
            except Exception:
                pass
            pressed.discard(key)

    def release_all() -> None:
        _release(list(pressed))

    def _combo(keys: list[str]) -> None:
        """原子组合键（按下→抬起整段）。已在按住的修饰键不重复按：
        否则 hotkey 结尾的 keyUp 会把用户正按着的 Shift 松掉。"""
        seq = [_norm_key(str(c)) for c in keys]
        if not seq:
            return
        extra = [k for k in seq[:-1] if k in _PYAGUI_MODS and k not in pressed]
        pyautogui.hotkey(*extra, seq[-1])

    def inject(ev: dict) -> None:
        t = ev.get("t")
        mods = [str(m) for m in (ev.get("mods") or ())]
        # 坐标：控制页发归一化 0..1，映射到真实分辨率
        if "x" in ev and "y" in ev:
            x = int(float(ev["x"]) * sw)
            y = int(float(ev["y"]) * sh)
        if t == "press":
            # 带 mods 的单键 = 组合键：一次性按下再抬起
            k = str(ev.get("k", ""))
            if not k:
                return
            if mods:
                _combo(mods + [k])
                return
            try:
                pyautogui.press(_norm_key(k))
            except (KeyError, ValueError):
                if len(k) == 1:  # pyautogui 不认识的字符退回文本粘贴
                    _paste_text(k)
                else:
                    raise
            return
        # 事件自带的 mods 若尚未按住（控制端没发过 keydown），临时按住再用，
        # 让「Ctrl+滚轮缩放」「Shift+点击多选」成立；动作结束按相反顺序释放
        tmp = _hold(mods)
        try:
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
            elif t == "keydown":
                k = str(ev.get("k", ""))
                if k:
                    key = _norm_key(k)
                    if key in _PYAGUI_MODS:
                        if key not in pressed:  # 保持按住，等 keyup
                            pyautogui.keyDown(key)
                            pressed.add(key)
                    else:
                        pyautogui.press(key)  # 非修饰键：原子按下+抬起
            elif t == "keyup":
                k = str(ev.get("k", ""))
                if k:
                    key = _norm_key(k)
                    if key in pressed or key in _PYAGUI_MODS:
                        _release([key])
            elif t == "key":
                # ev.k: 单键名（pyautogui 命名）；ev.combo: ["ctrl","c"]
                combo = ev.get("combo")
                k = str(ev.get("k", ""))
                if combo:
                    _combo([str(c) for c in combo])
                elif k and mods:
                    _combo(mods + [k])
                elif k:
                    pyautogui.press(_norm_key(k))
            elif t == "text":
                # 中文/任意文本走剪贴板粘贴，避免 typewrite 不支持非 ASCII
                _paste_text(str(ev.get("v", "")))
        finally:
            _release(tmp[::-1])  # 反向释放：后按下的先抬起

    return inject, (sw, sh), release_all


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


# ---------------------------------------------------------------- 多显示器

def list_screens() -> list[dict]:
    """协议 `screens.list`：id 即显示器下标（顺序与 screens.py 一致）。

    数据源优先 mss；macOS 上 mss 被 TCC 挡住（monitors 只有 0×0）时回落到 Quartz，
    此时抓屏走 screencapture 通道，仍然能出画面。
    """
    try:
        mons = list_monitors()
    except Exception as e:
        print(f"[agent] 枚举显示器失败: {e}", flush=True)
        return []
    return [{
        "id": i,
        "w": int(m["width"]),
        "h": int(m["height"]),
        "x": int(m["left"]),
        "y": int(m["top"]),
        "name": m["name"],
        "primary": bool(m["primary"]),
    } for i, m in enumerate(mons)]


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

    # 稳定指纹：机器名+系统+MAC 派生。注意 macOS 上 uuid.getnode() 拿不到 MAC 时
    # 会退化成随机值，指纹就变了 —— 所以设备 id 必须落盘，不能只靠指纹。
    fp = f"{platform.node()}-{SYSTEM}-{uuid.getnode():x}"
    want_id, id_src = resolve_device_id(args.device_id, args.new_device, fp)

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
        # 重连/重启都带上固定 device_id：服务端按 device_id/指纹去重，不再每起一次多一条设备
        init_body = {"device_name": args.name, "uuid": fp, "os": SYSTEM}
        fixed = want_id or reuse_device
        if fixed:
            init_body["device_id"] = fixed
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
        print(f"[agent] device={device_id}（{id_src}） room={cfg['room_id']}", flush=True)
        print(f"[agent] 手机打开 {args.server}/control 登录同一手机号即可控制", flush=True)

    inject, (sw, sh), release_all = _init_input()
    screens = list_screens()
    cur_screen = 0
    if screens:  # hello.screen 用真实主屏尺寸（pyautogui.size 在多屏下不一定准）
        sw, sh = screens[0]["w"], screens[0]["h"]
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
            mark_activity()
            await ws.send(json.dumps(obj, ensure_ascii=False))

        # 运行时画质参数（控制页 stream.config 可动态调，无需重启 Agent）
        stream_cfg = {"fps": args.fps, "quality": args.quality, "width": args.width}
        capture_mon = [0]  # JPEG 兜底通路当前抓的显示器（screen.select 时改）

        # WebRTC 媒体（首选）：H.264 + SRTP/UDP，信令仍走本 WS
        rtc = None
        if args.transport in ("webrtc", "both"):
            try:
                try:
                    from .webrtc_media import WebRTCMedia
                except ImportError:
                    from webrtc_media import WebRTCMedia

                def _on_rtc_state(state: str) -> None:
                    # WebRTC 连上后暂停 JPEG 推流（省 CPU/带宽）；断开则自动恢复兜底
                    if state == "connected":
                        streaming.clear()
                    elif state in ("failed", "closed", "disconnected"):
                        streaming.set()

                rtc = WebRTCMedia(
                    send_json=send_json,
                    width=args.width,
                    fps=min(30, args.fps),
                    bitrate_kbps=args.bitrate,
                    on_state=_on_rtc_state,
                    audio=not args.no_audio,
                    audio_device=args.audio_device,
                    monitor=cur_screen,
                    screen_count=max(1, len(screens)),
                    # 必须带 flush：stdout 被重定向到管道/文件时 print 会块缓冲，
                    # 日志要实时可见（QA 抓日志、联调对表都依赖这个）
                    log=lambda m: print(m, flush=True),
                )
            except Exception as e:  # aiortc 未安装等 → 自动退回 JPEG
                print(f"[agent] WebRTC 不可用（{e}），退回 JPEG 推流", flush=True)
                rtc = None

        media_kind = "webrtc" if rtc else "jpeg"
        audio_ok = bool(rtc and rtc.audio_ok)
        print(f"[agent] media={media_kind} audio={'on' if audio_ok else 'off'} "
              f"screens={len(screens)}", flush=True)

        # 剪贴板同步（轮询在后台，未 enable 时只空转）
        clips = ClipboardSync(send_json=send_json, log=print)
        clips.start()

        async def send_hello() -> None:
            scr = {"w": sw, "h": sh}
            if screens:
                scr = {"w": screens[cur_screen]["w"], "h": screens[cur_screen]["h"]}
            await send_json({"p": "agent.hello", "name": args.name, "os": SYSTEM,
                             "screen": scr, "media": media_kind,
                             "audio": audio_ok, "screens": len(screens),
                             "stream": dict(stream_cfg)})
            if screens:
                await send_json({"p": "screens", "current": cur_screen, "list": screens})
            else:
                # 没显示器/没屏录授权：让控制端提示原因而不是黑屏转圈。
                # 每次 hello（含 peer.join 重发）都带上，后进房的客户端也能收到。
                await send_json({"p": "agent.error", "err": "screen_permission"})

        if not screens:
            # 启动自检：进程不退出——信令、输入、剪贴板仍然可用
            print("[agent] 无可用显示器或缺少屏幕录制授权（monitors 为空）", flush=True)
        await send_hello()

        async def rx() -> None:
            nonlocal cur_screen
            async for raw in ws:
                if isinstance(raw, bytes):
                    continue  # Agent 不消费对端二进制
                ev = json.loads(raw)
                p = ev.get("p", "")
                if p == "peer.join":
                    # 新控制端进房：重发 hello（对方可能错过首次广播）+ 能力声明
                    await send_hello()
                    continue
                try:
                    if p == "rtc.offer" and rtc:
                        # 收到 offer 就停 JPEG 采集：macOS 同一条采集通道被并发抓屏会卡 30s
                        # （实测：JPEG 循环 + WebRTC 首帧同时 grab → 双双超时）
                        streaming.clear()
                        try:
                            await rtc.handle_offer(ev.get("sdp", ""), ev.get("ice"),
                                                   str(ev.get("peer") or "default"))
                        except Exception:
                            streaming.set()  # 协商失败就恢复 JPEG 兜底
                            raise
                    elif p == "rtc.ice" and rtc:
                        await rtc.handle_ice(ev.get("candidate", ""), ev.get("sdpMid"),
                                             ev.get("sdpMLineIndex"),
                                             str(ev.get("peer") or "default"))
                    elif p == "rtc.close" and rtc:
                        await rtc.close()
                        streaming.set()
                    elif p == "input":
                        inject(ev)
                    elif p == "screen.select":
                        idx = int(ev.get("id", 0))
                        if 0 <= idx < len(screens):
                            cur_screen = idx
                            capture_mon[0] = idx
                            if rtc:
                                await rtc.select_screen(idx)
                            await send_json({"p": "screen.selected", "id": idx})
                        else:
                            await send_json({"p": "agent.error", "err": f"无效屏幕 {idx}"})
                    elif p == "clip":
                        if ev.get("dir") == "up":
                            await asyncio.to_thread(clips.apply_up, str(ev.get("text", "")))
                    elif p == "clip.sync":
                        clips.set_enabled(bool(ev.get("enable")))
                    elif p == "view.only":
                        # 只观看时清掉按住的修饰键，避免远端卡住 Shift
                        if ev.get("enable"):
                            release_all()
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
                        if rtc:
                            rtc.set_config(width=ev.get("width"), fps=ev.get("fps"),
                                           bitrate_kbps=ev.get("bitrate"))
                        await send_json({"p": "stream.config.ack", **stream_cfg,
                                         "media": media_kind,
                                         "audio": audio_ok,
                                         "bitrate": rtc.bitrate_bps // 1000 if rtc else 0})
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
                err_sent = [False]
                use_pil = [False]  # JPEG 通路降级后端（macOS: screencapture）
                slow = [0]         # 连续慢抓屏次数（避免一次争用就永久降级）
                fails = [0]        # 连续抓屏失败次数（用于退避，别空转）

                def _notify_once(err: str) -> None:
                    if err_sent[0]:
                        return
                    err_sent[0] = True
                    loop.call_soon_threadsafe(
                        lambda: asyncio.create_task(send_json({"p": "agent.error", "err": err})))

                with _new_mss() as sct:
                    while not stop.is_set():
                        # WebRTC 连上后 streaming 会被清掉：此时必须彻底停止抓屏，
                        # 否则会和 WebRTC 抢同一个屏幕采集通道（macOS 上表现为
                        # 后到的采集调用阻塞 30s），并发两路抓屏也白烧 CPU。
                        if not streaming.is_set():
                            time.sleep(0.3)
                            continue
                        t0 = time.monotonic()
                        interval = 1.0 / stream_cfg["fps"]
                        try:
                            # 无授权时 mss 只给 0×0 的虚拟项：先回落到 Quartz 列表，
                            # 有几何信息就能用 screencapture 通道出图
                            mons = [m for m in sct.monitors[1:]
                                    if m["width"] > 0 and m["height"] > 0]
                            if not mons:
                                alt = list_monitors()
                                if not alt:
                                    _notify_once("screen_permission")
                                    time.sleep(0.5)
                                    continue
                                mons = alt
                                use_pil[0] = True  # mss 拿不到，只能用 screencapture
                            m = mons[min(capture_mon[0], len(mons) - 1)]
                            if use_pil[0]:  # 降级后端：macOS 的 screencapture，不受 mss 那条 TCC 通道限制
                                img = grab_screencapture((m["left"], m["top"],
                                                          m["left"] + m["width"],
                                                          m["top"] + m["height"]))
                            else:
                                g0 = time.monotonic()
                                shot = sct.grab(m)
                                dt = time.monotonic() - g0
                                # 连续两次慢抓屏才切后端：单次慢可能只是和 WebRTC 抢通道
                                if SYSTEM == "Darwin" and dt > 3:
                                    slow[0] += 1
                                    if slow[0] >= 3:
                                        use_pil[0] = True
                                        _notify_once("screen_timeout")
                                        print("[agent] JPEG 抓屏连续超时，切到 screencapture 后端",
                                              flush=True)
                                else:
                                    slow[0] = 0
                                img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
                            w = stream_cfg["width"]
                            if img.width > w:
                                img = img.resize((w, max(2, int(img.height * w / img.width))),
                                                 Image.BILINEAR)
                            # 画面没变则不重复编码（省带宽）；但每 2s 保活一帧
                            h = hashlib.md5(img.tobytes()[::997]).digest()
                            now = time.monotonic()
                            fails[0] = 0
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
                        except Exception as e:
                            # mss 抛错（无授权/显示器消失）：macOS 上切 screencapture 再试
                            fails[0] += 1
                            if SYSTEM == "Darwin" and not use_pil[0] and fails[0] >= 2:
                                use_pil[0] = True
                                _notify_once("screen_permission")
                                print(f"[agent] JPEG 抓屏失败（{e}），切到 screencapture 后端",
                                      flush=True)
                            if fails[0] >= 3:
                                if fails[0] % 10 == 3:
                                    print(f"[agent] JPEG 抓屏连续失败 {fails[0]} 次，降频重试", flush=True)
                                if fails[0] >= 10:
                                    # 能枚举到屏却抓不到像素：睡屏/遮罩/授权被撤，让控制端提示
                                    _notify_once("screen_permission")
                                time.sleep(1.0)
                            else:
                                time.sleep(0.2)  # 单帧失败跳过，不断流
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
                    mark_activity()
            finally:
                stop.set()
                cap.cancel()

        try:
            await asyncio.gather(rx(), tx())
        finally:
            # 断链必须松开所有修饰键 + 停剪贴板轮询，否则重连后远端卡 Shift
            release_all()
            await clips.stop()
            if rtc:
                await rtc.close()  # 断链时释放 PC，避免重连后重复协商


LAST_DEVICE: str | None = None  # 断线重连时复用，避免旧服务端堆重复设备


def main() -> int:
    ap = argparse.ArgumentParser(description="轻量远程桌面 Agent")
    # --version 用 argparse 的 version action：它在必填参数校验之前就触发退出，
    # 所以 `uu-agent --version` 不需要 --server 也能跑（自更新逻辑靠它取当前版本）。
    ap.add_argument("--version", action="version", version=f"uu-agent {AGENT_VERSION}")
    ap.add_argument("--server", required=True, help="https://<host>:8443")
    ap.add_argument("--mobile", help="登录手机号（与控制页一致）")
    ap.add_argument("--token", help="复用已有登录 token（App 一体化模式，不重复登录）")
    ap.add_argument("--name", default=platform.node(), help="设备名")
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--quality", type=int, default=75, help="JPEG 质量 30-90（仅 jpeg 传输）")
    ap.add_argument("--width", type=int, default=1920, help="帧最大宽度（越大越清晰）")
    ap.add_argument("--transport", choices=["webrtc", "jpeg", "both"], default="webrtc",
                    help="媒体传输：webrtc(默认，H.264/UDP，aiortc 缺失时自动退回 jpeg) / jpeg / both")
    ap.add_argument("--bitrate", type=int, default=8000,
                    help="WebRTC 目标码率 kbps（默认 8000；1080p 屏幕 8M 约 45dB PSNR）")
    ap.add_argument("--no-audio", action="store_true", help="关闭音频采集（默认开）")
    ap.add_argument("--audio-device", default=None,
                    help="音频输入设备名/序号（系统内录需指向 BlackHole 等虚拟声卡）")
    ap.add_argument("--device-id", default=None,
                    help="显式指定设备 id（默认复用 ~/.uu-agent/device_id）")
    ap.add_argument("--new-device", action="store_true",
                    help="强制注册一台新设备（会重写 ~/.uu-agent/device_id）")
    ap.add_argument("--insecure", action="store_true", help="跳过证书校验（自签调试）")
    ap.add_argument("--no-update", action="store_true",
                    help="关闭被控端自更新（默认开；仅在 PyInstaller 打包产物里生效）")
    args = ap.parse_args()
    if not args.mobile and not args.token:
        ap.error("需要 --mobile 或 --token 之一")
    print(f"[agent] uu-agent {AGENT_VERSION}（{platform.system()} {platform.machine()}）",
          flush=True)
    if not args.no_update:
        try:
            try:
                from .updater import start_background as _start_updater
            except ImportError:
                from updater import start_background as _start_updater
            _start_updater(busy=is_busy)
        except Exception as e:  # 自更新不可用不能影响主链路
            print(f"[agent] 自更新未启用：{e}", file=sys.stderr, flush=True)
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