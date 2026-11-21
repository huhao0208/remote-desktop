"""安全与电源动作（被控端）。

四块能力，全部按「失败只回报错、不抛异常」写——远控链路上任何一次
异常都不该把整条连接带下去：

1. 防窥遮罩：起/停 `privacy_overlay.py` 子进程（黑屏 / 壁纸 / 熄屏）；
2. 电源动作：锁屏、重启、关机（带倒计时撤销）、任务管理器；
3. 被控静音：只静音扬声器输出，不碰采集设备（官方「被控静音」语义）；
4. 会话策略：结束远程自动锁屏（官方 `autoLock`）。

系统命令都带超时。macOS 的锁屏/重启走 osascript（不需要 root），
`shutdown` 系命令需要 root，所以不用。
"""
from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Optional, Sequence

SYSTEM = __import__("platform").system()  # 避免顶层 import platform 与 agent 重复

PRIVACY_MODES = ("off", "blank", "screenoff", "wallpaper")
_MODE_LABEL = {
    "off": "不启用",
    "blank": "黑屏防护",
    "screenoff": "关闭显示屏",
    "wallpaper": "隐私屏保",
}

WALLPAPER_MAX_BYTES = 2 * 1024 * 1024
WALLPAPER_MIN_W, WALLPAPER_MIN_H = 1920, 1080


# ------------------------------------------------------------------ 路径

def _home_dir() -> Path:
    """与 `agent._device_id_path()` 保持同一落点：
    Windows `%APPDATA%\\uu-agent`，其余 `~/.uu-agent`。

    两边不一致的后果不是洁癖问题——卸载/备份脚本按一个路径清理，
    另一个目录里的配置会被留下，升级后行为「莫名」不同。
    """
    if SYSTEM == "Windows":
        base = os.environ.get("APPDATA")
        return (Path(base) if base else Path(os.path.expanduser("~"))) / "uu-agent"
    return Path(os.path.expanduser("~")) / ".uu-agent"


def _privacy_dir() -> Path:
    d = _home_dir() / "privacy"
    try:
        d.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    return d


def _cfg_path() -> Path:
    return _home_dir() / "security.json"


# ------------------------------------------------------------------ 配置

_DEFAULT_CFG: dict[str, Any] = {"auto_lock": False}


def load_cfg() -> dict[str, Any]:
    cfg = dict(_DEFAULT_CFG)
    try:
        raw = json.loads(_cfg_path().read_text("utf-8"))
        if isinstance(raw, dict):
            for k in _DEFAULT_CFG:
                if k in raw:
                    cfg[k] = bool(raw[k])
    except (OSError, ValueError):
        pass
    return cfg


def save_cfg(cfg: dict[str, Any]) -> None:
    try:
        _cfg_path().parent.mkdir(parents=True, exist_ok=True)
        _cfg_path().write_text(json.dumps(cfg, ensure_ascii=False), "utf-8")
    except OSError:
        pass


# ------------------------------------------------------------------ 子进程启动

def _agent_entry() -> list[str]:
    """返回「启动 agent 自己」的命令前缀。

    PyInstaller 产物里 `sys.executable` 就是 uu-agent 本体；
    源码直跑时还得补上 agent.py 路径。
    """
    if getattr(sys, "frozen", False):
        return [sys.executable]
    here = Path(__file__).resolve().parent
    return [sys.executable, str(here / "agent.py")]


def _run(argv: Sequence[str], timeout: float = 6.0) -> tuple[bool, str]:
    """跑一条系统命令，返回 (ok, 输出/错误)。"""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        return False, f"命令不存在：{argv[0]}"
    except subprocess.TimeoutExpired:
        return False, "命令超时"
    except Exception as e:  # noqa: BLE001
        return False, str(e)
    if p.returncode != 0:
        msg = (p.stderr or p.stdout or "").strip().splitlines()
        return False, (msg[-1] if msg else f"退出码 {p.returncode}")
    return True, (p.stdout or "").strip()


# ------------------------------------------------------------------ 遮罩窗

class _Overlay:
    """遮罩窗子进程句柄。**只持有进程**，模式/时间等状态统一放 `_privacy`，
    避免两处状态各说一套。"""

    proc: Optional[subprocess.Popen] = None

    @classmethod
    def running(cls) -> bool:
        return cls.proc is not None and cls.proc.poll() is None

    @classmethod
    def stop(cls) -> None:
        p = cls.proc
        cls.proc = None
        if p is None or p.poll() is not None:
            return
        try:
            p.terminate()
            p.wait(timeout=3)
        except Exception:
            try:
                p.kill()
            except Exception:
                pass

    @classmethod
    def start(cls, mode: str, image: str, hint: str) -> tuple[bool, str]:
        cls.stop()
        geo = ""
        try:
            try:
                from .screens import list_monitors
            except ImportError:
                from screens import list_monitors

            geo = ";".join(
                f"{int(m['left'])},{int(m['top'])},{int(m['width'])},{int(m['height'])}"
                for m in list_monitors()
                if int(m.get("width") or 0) > 0)
        except Exception:
            geo = ""  # 枚举不到就退回主屏，总不能因为多屏探测失败就不遮

        log = _privacy_dir() / "overlay.log"
        argv = _agent_entry() + [
            "--privacy-overlay",
            "--mode", "wallpaper" if mode == "wallpaper" else "blank",
            "--screens", geo,
            "--hint", hint or "被控端已开启防窥 · 按 Esc 解除",
        ]
        if PRIVACY_ENGINE == "overlay":
            # 只有 overlay 引擎才要求「不进录屏」；熄屏引擎根本不起窗
            argv.append("--exclude-capture")
        if image:
            argv += ["--image", image]
        try:
            with open(log, "wb") as fh:
                proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL,
                                        stderr=fh, stdin=subprocess.DEVNULL)
        except Exception as e:  # noqa: BLE001
            return False, f"遮罩窗启动失败：{e}"

        # tkinter 起窗要 100–400ms；等一小会儿再判活，别把「还没起好」当失败
        deadline = time.monotonic() + 1.5
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                err = _tail(log, 3) or f"退出码 {proc.returncode}"
                return False, f"遮罩窗异常退出：{err}"
            time.sleep(0.1)
        cls.proc = proc
        return True, ""


def _tail(path: Path, lines: int) -> str:
    try:
        text = path.read_text("utf-8", errors="replace").strip().splitlines()
    except OSError:
        return ""
    return " / ".join(text[-lines:])


def privacy_state() -> dict[str, Any]:
    """当前防窥状态（hello / privacy.state / security.state 共用同一份口径）。"""
    mode = str(_privacy["mode"])
    alive = _Overlay.running()
    since = float(_privacy["since"] or 0)
    out: dict[str, Any] = {
        "mode": mode,
        "label": _MODE_LABEL.get(mode, mode),
        "engine": PRIVACY_ENGINE,
        "alive": alive,
        "image": bool(_privacy["image"]),
        "since": int(since * 1000) if mode != "off" and since else 0,
    }
    if _privacy.get("wallpaper"):
        out["wallpaper"] = _privacy["wallpaper"]
    return out


def keep_display_off() -> None:
    """熄屏兜底心跳。

    现在只有 Windows 的 `screenoff` 档会真熄屏；旁人碰一下键盘屏幕会亮，
    这里隔几秒压回去。3 秒是取舍：足够快，旁人还没看清就黑了；
    又足够慢，不至于每秒 fork 一个进程。
    """
    if PRIVACY_ENGINE != "overlay":
        return
    if _privacy["mode"] == "screenoff":
        display_off()


def reset_on_disconnect() -> dict[str, Any]:
    """会话结束时收尾：撤遮罩、亮屏。

    不做这一步的后果很具体：控制端断线后用户面对一块黑屏，
    还以为机器坏了。
    """
    was = str(_privacy["mode"])
    if was != "off":
        _Overlay.stop()
        if was == "screenoff":
            display_on()
        _privacy.update({"mode": "off", "since": 0.0})
    return {"privacy": "off", "was": was}


# ------------------------------------------------------------------ 壁纸

def save_wallpaper(data_b64: str) -> tuple[bool, str, dict[str, Any]]:
    """落盘自定义隐私屏保。返回 (ok, err, meta)；meta 带尺寸与是否低于官方规格。"""
    payload = data_b64.split(",", 1)[-1] if data_b64.startswith("data:") else data_b64
    try:
        raw = base64.b64decode(payload, validate=False)
    except Exception as e:  # noqa: BLE001
        return False, f"图片解码失败：{e}", {}
    if not raw:
        return False, "图片内容为空", {}
    if len(raw) > WALLPAPER_MAX_BYTES:
        return False, f"图片超过 2MB（{len(raw) / 1048576:.1f}MB）", {}
    try:
        from PIL import Image
    except Exception as e:  # noqa: BLE001
        return False, f"缺少 Pillow：{e}", {}
    try:
        im = Image.open(__import__("io").BytesIO(raw))
        im.load()
        w, h = im.size
        im = im.convert("RGB")
        out = _privacy_dir() / "wallpaper.png"
        im.save(out, "PNG")
    except Exception as e:  # noqa: BLE001
        return False, f"图片无法识别：{e}", {}
    meta = {
        "w": w, "h": h,
        "bytes": out.stat().st_size if out.exists() else 0,
        # 官方要求 ≥1920×1080；小于这个尺寸照样能用，只是提示一下，
        # 免得在小屏机器上直接把人卡死（硬拦比误放更烦）
        "below_spec": w < WALLPAPER_MIN_W or h < WALLPAPER_MIN_H,
    }
    return True, "", meta


def wallpaper_path() -> str:
    p = _privacy_dir() / "wallpaper.png"
    return str(p) if p.exists() else ""


# ------------------------------------------------------------------ 防窥

# 引擎判定来自实测，不是猜的：
#
# | 平台    | 遮罩窗 | 熄屏 | 结论 |
# |---------|--------|------|------|
# | Windows | 可用（`WDA_EXCLUDEFROMCAPTURE` 让窗口不进录屏） | 可用 | overlay |
# | macOS   | 可用（`NSWindow.sharingType=0`，CG 采集会剔除该窗） | **采集直接失效** | overlay（不含 screenoff） |
# | Linux   | 会被自己采集进去（X11 无排除 API） | 依赖 DMPS，Wayland 无 | unsupported |
#
# macOS 的实测数据（2026-11-21，macOS 15.8.1 / Tk 9.0 / 2048×1280，遮罩纯色 #101010）：
#   - 默认 sharingType 时，取 loginwindow 以下的窗口层做合成（等价于整屏采集里遮罩那一层），
#     91.7% 像素是 #101010；设成 sharingType=0 后同一合成里只剩 0.2%，
#     中心点从 (16,16,16) 变成桌面内容 —— 即 mss 走的 `CGWindowListCreateImage`
#     会把这个窗口剔掉，遮罩不会被录进去。
#   - `screencapture -l <win>` 在 sharingType=0 后直接报 `could not create image from window`。
#   - 熄屏仍然不可用：`pmset displaysleepnow` 之后 mss 的 monitors 变成 0×0，
#     `screencapture` 报 `could not create image from display` —— 熄屏等于断流。
#
# 已知风险（实测未覆盖）：macOS 15 起 `screencapture` CLI 链接了 ScreenCaptureKit，
#   而 SCK 的窗口级截图对 sharingType=0 的窗口会返回纯黑图而不是桌面内容。
#   真走 SCK 的整屏采集是否也剔除本窗，本机锁屏状态下无法实测；
#   好在主采集路径（mss）不经过 SCK，screencapture 只在 mss 被 TCC 挡住时兜底。
PRIVACY_ENGINE = "overlay" if SYSTEM in ("Windows", "Darwin") else "unsupported"
_PRIVACY_UNSUPPORTED_ERR = (
    "当前被控端不支持防窥：Linux 上遮罩会被采集一起录进去，"
    "而熄屏又会让采集彻底失效"
)

_privacy: dict[str, Any] = {"mode": "off", "image": "", "since": 0.0}


def set_privacy(mode: str, image_b64: str = "", hint: str = "") -> dict[str, Any]:
    mode = (mode or "").strip()
    if mode not in PRIVACY_MODES:
        return {"ok": False, "err": f"未知防窥模式 {mode}", **privacy_state()}

    if mode == "off":
        _Overlay.stop()
        _privacy.update({"mode": "off", "since": 0.0})
        return {"ok": True, **privacy_state()}

    if mode == "screenoff" and SYSTEM == "Darwin":
        # macOS 熄屏后 mss 的 monitors 直接变 0×0、screencapture 报
        # `could not create image from display` —— 开了就是控制端全黑，
        # 所以这个模式在 macOS 上直接拒绝，而不是给个「看起来开了」的开关。
        return {"ok": False,
                "err": "macOS 上「关闭显示屏」会让远程画面断流（实测两种采集后端都取不到图），"
                       "请改用黑屏防护或隐私屏保",
                **privacy_state()}

    if PRIVACY_ENGINE != "overlay":
        return {"ok": False, "err": _PRIVACY_UNSUPPORTED_ERR, **privacy_state()}

    image = str(_privacy["image"] or "")
    if image_b64:
        ok, err, meta = save_wallpaper(image_b64)
        if not ok:
            return {"ok": False, "err": err, **privacy_state()}
        image = wallpaper_path()
        _privacy["image"] = image
        _privacy["wallpaper"] = meta
    if mode == "wallpaper" and not image:
        return {"ok": False, "err": "还没设置隐私屏保图片", **privacy_state()}

    ok, err = _Overlay.start("wallpaper" if mode == "wallpaper" else "blank",
                             image if mode == "wallpaper" else "", hint)
    if not ok:
        # 遮罩起不来就整体失败：此时若继续「假装开了」，用户会以为已防护
        return {"ok": False, "err": err, **privacy_state()}

    disp_ok, disp_err = True, ""
    if mode == "screenoff":
        # 窗口已经挡住了，熄屏是加一层；失败的化不算整体失败
        disp_ok, disp_err = display_off()

    _privacy.update({"mode": mode, "since": time.time()})
    out: dict[str, Any] = {"ok": True, **privacy_state()}
    out["display"] = "off" if mode == "screenoff" and disp_ok else "on"
    if not disp_ok:
        out["display_err"] = disp_err
    return out


# ------------------------------------------------------------------ 熄屏 / 唤醒

def display_off() -> tuple[bool, str]:
    if SYSTEM == "Darwin":
        return _run(["pmset", "displaysleepnow"])
    if SYSTEM == "Windows":
        try:
            import ctypes

            # HWND_BROADCAST / WM_SYSCOMMAND / SC_MONITORPOWER(2=off)
            ctypes.windll.user32.SendMessageW(-1, 0x0112, 0xF170, 2)
            return True, ""
        except Exception as e:  # noqa: BLE001
            return False, str(e)
    return _run(["xset", "dpms", "force", "off"])


def display_on() -> tuple[bool, str]:
    if SYSTEM == "Darwin":
        # caffeinate 拉一次 user activity 就能把显示器唤醒，比私 API 稳
        if shutil.which("caffeinate"):
            return _run(["caffeinate", "-u", "-t", "1"])
        return False, "缺 caffeinate"
    if SYSTEM == "Windows":
        try:
            import ctypes

            ctypes.windll.user32.SendMessageW(-1, 0x0112, 0xF170, -1)  # -1 = on
            return True, ""
        except Exception as e:  # noqa: BLE001
            return False, str(e)
    return _run(["xset", "dpms", "force", "on"])


# ------------------------------------------------------------------ 锁屏 / 重启 / 任务管理器

def lock_screen() -> tuple[bool, str]:
    if SYSTEM == "Windows":
        return _run(["rundll32.exe", "user32.dll,LockWorkStation"])
    if SYSTEM == "Darwin":
        # CGSession 在新系统上可能已移除，退回 Ctrl+Cmd+Q（走辅助功能，权限已有）
        cg = ("/System/Library/CoreServices/Menu Extras/User.menu/Contents/"
              "Resources/CGSession")
        if os.path.exists(cg):
            ok, msg = _run([cg, "-suspend"])
            if ok:
                return True, ""
        return _run(["osascript", "-e",
                     'tell application "System Events" to keystroke "q" '
                     'using {control down, command down}'])
    for argv in (["loginctl", "lock-session"], ["xdg-screensaver", "lock"],
                 ["gnome-screensaver-command", "-l"]):
        if shutil.which(argv[0]):
            ok, msg = _run(argv)
            if ok:
                return True, ""
            last = msg
    return False, locals().get("last", "没有可用的锁屏命令")


def reboot_cmd(seconds: int) -> list[str]:
    if SYSTEM == "Windows":
        return ["shutdown", "/r", "/t", str(max(0, seconds))]
    if SYSTEM == "Darwin":
        # 需要 root 的 shutdown 用不了，走 System Events（会弹确认，属正常）
        return ["osascript", "-e", 'tell application "System Events" to restart']
    return ["shutdown", "-r", f"+{max(1, seconds // 60)}"]


def shutdown_cmd(seconds: int) -> list[str]:
    if SYSTEM == "Windows":
        return ["shutdown", "/s", "/t", str(max(0, seconds))]
    if SYSTEM == "Darwin":
        return ["osascript", "-e", 'tell application "System Events" to shut down']
    return ["shutdown", "-h", f"+{max(1, seconds // 60)}"]


def cancel_cmd() -> list[str]:
    """撤销还没执行的关机/重启。macOS 的 osascript 对话框只能由用户点取消。"""
    if SYSTEM == "Windows":
        return ["shutdown", "/a"]
    if SYSTEM == "Darwin":
        return []
    return ["shutdown", "-c"]


def task_manager() -> tuple[bool, str]:
    if SYSTEM == "Windows":
        return _run(["taskmgr.exe"])
    if SYSTEM == "Darwin":
        return _run(["open", "-a", "Activity Monitor"])
    for name in ("gnome-system-monitor", "ksysguard", "plasma-systemmonitor", "xfce4-taskmanager"):
        if shutil.which(name):
            try:
                subprocess.Popen([name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return True, ""
            except Exception as e:  # noqa: BLE001
                return False, str(e)
    return False, "没有找到任务管理器"


def capabilities() -> list[str]:
    caps = ["lock", "shutdown", "reboot"]
    if SYSTEM == "Windows" or shutil.which("open") or SYSTEM == "Linux":
        caps.append("taskmgr")
    return caps


# ------------------------------------------------------------------ 静音

def set_mute(on: bool) -> tuple[bool, bool, str]:
    """静音/取消静音**扬声器输出**。返回 (ok, 实际状态, 错误)。

    注意语义：只动输出设备，采集（录音）通道不受影响 —— 这样「被控静音」
    之后控制端仍然能听到声音，与官方一致。若哪天改用 loopback 采集，
    这里要跟着改，否则控制端会一起被静音。
    """
    if SYSTEM == "Darwin":
        ok, msg = _run(["osascript", "-e",
                        f"set volume output muted {'true' if on else 'false'}"])
        return ok, on if ok else False, "" if ok else msg
    if SYSTEM == "Linux":
        if shutil.which("pactl"):
            ok, msg = _run(["pactl", "set-sink-mute", "@DEFAULT_SINK@", "1" if on else "0"])
            return ok, on if ok else False, "" if ok else msg
        ok, msg = _run(["amixer", "-q", "sset", "Master", "mute" if on else "unmute"])
        return ok, on if ok else False, "" if ok else msg
    # Windows：CoreAudio 的 COM 调用放在子进程里跑 —— vtable 索引一旦写错
    # 是访问违例（直接段错误），不能让它发生在 agent 主进程里。
    argv = _agent_entry() + ["--mute-helper", "on" if on else "off"]
    ok_run, out = _run(argv, timeout=15)
    if not ok_run:
        return False, False, out
    try:
        data = json.loads(out.splitlines()[-1])
    except Exception:  # noqa: BLE001
        return False, False, f"静音助手输出异常：{out[:120]}"
    return bool(data.get("ok")), bool(data.get("muted")), str(data.get("err") or "")
