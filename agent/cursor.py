"""系统光标可见性 + 「warp 语义」相对位移（协议 v3 §3）。

为什么单独一个模块：这两件事都是**平台专有 API**，而且都要求「失败不打断远控」。
把它们从 agent.py 里拆出来，是为了让 `import cursor` 在任何平台都成功（agent
主进程可以无条件加载），平台相关的符号全部推迟到函数内部——顶层不许出现
`windll` / `objc` 之类的名字，否则 macOS 上 `import cursor` 直接 ImportError，
整个被控端起不来。这与 `win_audio.py` 的约束是同一个理由。

三个语义要点：

1. **`ShowCursor` 是计数器，不是开关**。`ShowCursor(FALSE)` 只是把计数 -1，
   计数 < 0 才真正隐藏；系统里任何一处不成对的调用都会让「隐藏一次」看起来无效。
   所以 Windows 侧要循环到读回状态一致，而不是调一次就返回成功。
2. **读回校验**。hide/show 都可能被系统忽略（权限、显示器切换、别的程序抢），
   返回值不代表结果。设完必须读回真实状态，不一致就 `ok=False`——远控里
   「谎报成功」比「报失败」伤害大得多：控制端会按成功去隐藏本机光标，
   用户看到的是一个没有指针的画面。
3. **`move_rel` 必须是 warp，不是 move**。协议 §3 要的是「不吃系统指针加速」：
   `CGWarpMouseCursorPosition` / `SetCursorPos` 都是把指针直接放到某个绝对坐标，
   不经过 OS 的加速度曲线；pyautogui 的 `moveRel` 走的是注入相对事件，会被加速，
   所以只能当 Linux 兜底。

用户光标状态保护：模块记住「我们改之前是什么样」（`_original`），会话结束时
用 `restore()` 还原，而不是无脑 `set_visible(True)`。用户本来就把光标隐藏了
（演示、录屏、游戏），我们没资格替他把光标弄出来。
"""
from __future__ import annotations

import ctypes
import platform
from typing import Optional, Tuple

SYSTEM = platform.system()

_ENGINES = {"Windows": "win-show-cursor", "Darwin": "mac-cgdisplay"}

# 我们上一次**成功**设置成的状态；None = 本次会话还没动过光标
_applied: Optional[bool] = None
# 我们介入**之前**的真实状态；None = 读不到（保守按「可见」还原）
_original: Optional[bool] = None


def engine() -> str:
    """当前平台用哪个引擎实现光标隐藏。Linux 一律 unsupported。

    Linux 不是「做不到」，而是 X11/Wayland 下没有一个统一的、能可靠复原的
    全局光标可见性 API；与其给个时灵时不灵的开关，不如让控制端把选项藏掉
    （协议 §3 最后一条）。
    """
    return _ENGINES.get(SYSTEM, "unsupported")


# ------------------------------------------------------------------ Windows

class _POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


class _CURSORINFO(ctypes.Structure):
    _fields_ = [("cbSize", ctypes.c_uint32),
                ("flags", ctypes.c_uint32),
                ("hCursor", ctypes.c_void_p),
                ("ptScreenPos", _POINT)]


_CURSOR_SHOWING = 0x00000001
_user32 = None
_win_broken = False


def _win() -> Optional[object]:
    """惰性加载 user32。只有 Windows 上才会碰 `ctypes.windll`。"""
    global _user32, _win_broken
    if _user32 is not None or _win_broken:
        return _user32
    if SYSTEM != "Windows":
        _win_broken = True
        return None
    try:
        _user32 = ctypes.windll.user32
        _user32.ShowCursor.restype = ctypes.c_int
        _user32.ShowCursor.argtypes = [ctypes.c_int]
        _user32.GetCursorInfo.restype = ctypes.c_int
        _user32.GetCursorInfo.argtypes = [ctypes.POINTER(_CURSORINFO)]
        _user32.GetCursorPos.restype = ctypes.c_int
        _user32.GetCursorPos.argtypes = [ctypes.POINTER(_POINT)]
        _user32.SetCursorPos.restype = ctypes.c_int
        _user32.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
        _user32.GetSystemMetrics.restype = ctypes.c_int
        _user32.GetSystemMetrics.argtypes = [ctypes.c_int]
    except Exception:
        _user32, _win_broken = None, True
    return _user32


def _win_visible() -> Optional[bool]:
    u = _win()
    if u is None:
        return None
    ci = _CURSORINFO()
    ci.cbSize = ctypes.sizeof(_CURSORINFO)
    if not u.GetCursorInfo(ctypes.byref(ci)):
        return None
    return bool(ci.flags & _CURSOR_SHOWING)


def _win_set_visible(want: bool) -> Tuple[bool, str, str]:
    u = _win()
    if u is None:
        return (False, engine(), "无法加载 user32.dll")
    try:
        for _ in range(64):     # 计数器最多 ±32767，64 次足够跨过常见的不配对
            now = _win_visible()
            if now is None:
                return (False, engine(), "GetCursorInfo 读不回光标状态")
            if now == want:
                return (True, engine(), "")
            u.ShowCursor(1 if want else 0)
        return (False, engine(), "ShowCursor 调用 64 次仍未达到目标状态")
    except Exception as e:      # noqa: BLE001
        return (False, engine(), f"{type(e).__name__}: {e}")


# ------------------------------------------------------------------ macOS

class _CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class _CGSize(ctypes.Structure):
    _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]


class _CGRect(ctypes.Structure):
    _fields_ = [("origin", _CGPoint), ("size", _CGSize)]


_CG_PATH = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
_CF_PATH = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"

_cg = None
_cf = None
_mac_broken = False


def _mac() -> Optional[object]:
    """惰性加载 CoreGraphics / CoreFoundation 并声明签名。

    签名必须显式声明：`CGWarpMouseCursorPosition` 收的是**按值传的结构体**
    （两个 double），不声明 argtypes 时 ctypes 会把它当指针传，指针值被当成
    坐标用——结果是光标瞬间飞到屏幕角落，而不是报错。
    """
    global _cg, _cf, _mac_broken
    if _cg is not None or _mac_broken:
        return _cg
    if SYSTEM != "Darwin":
        _mac_broken = True
        return None
    try:
        cg = ctypes.CDLL(_CG_PATH)
        cf = ctypes.CDLL(_CF_PATH)

        cg.CGMainDisplayID.restype = ctypes.c_uint32
        cg.CGDisplayHideCursor.restype = ctypes.c_int32
        cg.CGDisplayHideCursor.argtypes = [ctypes.c_uint32]
        cg.CGDisplayShowCursor.restype = ctypes.c_int32
        cg.CGDisplayShowCursor.argtypes = [ctypes.c_uint32]
        cg.CGDisplayBounds.restype = _CGRect
        cg.CGDisplayBounds.argtypes = [ctypes.c_uint32]
        cg.CGWarpMouseCursorPosition.restype = ctypes.c_int32
        cg.CGWarpMouseCursorPosition.argtypes = [_CGPoint]
        # boolean_t 是 32 位 int，不是 C99 bool
        cg.CGAssociateMouseAndMouseCursorPosition.restype = ctypes.c_int32
        cg.CGAssociateMouseAndMouseCursorPosition.argtypes = [ctypes.c_int]
        cg.CGEventCreate.restype = ctypes.c_void_p
        cg.CGEventCreate.argtypes = [ctypes.c_void_p]
        cg.CGEventGetLocation.restype = _CGPoint
        cg.CGEventGetLocation.argtypes = [ctypes.c_void_p]
        cf.CFRelease.restype = None
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        _cg, _cf = cg, cf
    except Exception:
        _cg, _cf, _mac_broken = None, None, True
    return _cg


def _mac_visible() -> Optional[bool]:
    """`CGCursorIsVisible` 在新系统上被标记 deprecated 但符号仍在；
    真取不到就返回 None（调用方退化成只信 CGError）。"""
    cg = _mac()
    if cg is None:
        return None
    try:
        fn = cg.CGCursorIsVisible
        fn.restype = ctypes.c_bool
        fn.argtypes = []
        return bool(fn())
    except Exception:
        return None


def _mac_set_visible(want: bool) -> Tuple[bool, str, str]:
    cg = _mac()
    if cg is None:
        return (False, engine(), "无法加载 CoreGraphics")
    try:
        display = cg.CGMainDisplayID()
        err = cg.CGDisplayShowCursor(display) if want else cg.CGDisplayHideCursor(display)
        if err != 0:
            return (False, engine(), f"CGError {err}")
        back = _mac_visible()
        if back is not None and back != want:
            return (False, engine(), "读写后光标可见性与目标不一致")
        return (True, engine(), "")
    except Exception as e:      # noqa: BLE001
        return (False, engine(), f"{type(e).__name__}: {e}")


# ------------------------------------------------------------------ 可见性

def _read_visible() -> Optional[bool]:
    if SYSTEM == "Windows":
        return _win_visible()
    if SYSTEM == "Darwin":
        return _mac_visible()
    return None


def _apply(visible: bool) -> Tuple[bool, str, str]:
    if SYSTEM == "Windows":
        return _win_set_visible(visible)
    if SYSTEM == "Darwin":
        return _mac_set_visible(visible)
    return (False, "unsupported", "当前被控端不支持隐藏系统光标")


def set_visible(visible: bool) -> Tuple[bool, str, str]:
    """设系统光标可见性，返回 `(ok, engine, err)`。

    幂等：已经是目标状态就不再调平台 API。Windows 上是必需的（`ShowCursor`
    是计数器，多调一次就要多调一次反向才能回到原状）；macOS 上则是为了不让
    hide 计数堆起来。
    """
    global _applied, _original
    want = bool(visible)

    if SYSTEM not in ("Windows", "Darwin"):
        return (False, "unsupported", "当前被控端不支持隐藏系统光标")
    if _applied == want:
        return (True, engine(), "")

    if _original is None:
        # 第一次介入：先记下真实状态，会话结束时才能原样还回去
        _original = _read_visible()

    ok, eng, err = _apply(want)
    if ok:
        _applied = want
    return (ok, eng, err)


def restore() -> Tuple[bool, str, str]:
    """会话结束 / 切回 `remote` 时把光标还原成「我们介入前」的样子。

    接线方在断开连接时应该调它而不是 `set_visible(True)`：后者会把用户
    自己隐藏的光标弄出来。
    """
    if _applied is None:
        return (True, engine(), "")
    target = True if _original is None else _original
    return set_visible(target)


# ------------------------------------------------------------------ 相对位移

def _mac_move_rel(dx: float, dy: float) -> None:
    cg = _mac()
    if cg is None:
        return
    try:
        ev = cg.CGEventCreate(None)
        if not ev:
            return
        try:
            pos = cg.CGEventGetLocation(ev)
        finally:
            _cf.CFRelease(ev)
        rect = cg.CGDisplayBounds(cg.CGMainDisplayID())
        nx = pos.x + dx
        ny = pos.y + dy
        if rect.size.width > 0 and rect.size.height > 0:
            nx = min(max(nx, rect.origin.x), rect.origin.x + rect.size.width - 1)
            ny = min(max(ny, rect.origin.y), rect.origin.y + rect.size.height - 1)
        cg.CGWarpMouseCursorPosition(_CGPoint(nx, ny))
        # warp 会让指针与鼠标设备「错位」一段时间（系统认为设备还在老位置，
        # 下一次物理移动会跳一下）。重新关联把两者对齐，手感才是连续的
        cg.CGAssociateMouseAndMouseCursorPosition(1)
    except Exception:           # noqa: BLE001 远控链路上不许抛
        return


def _win_move_rel(dx: float, dy: float) -> None:
    u = _win()
    if u is None:
        return
    try:
        pt = _POINT()
        if not u.GetCursorPos(ctypes.byref(pt)):
            return
        w = u.GetSystemMetrics(0)     # SM_CXSCREEN
        h = u.GetSystemMetrics(1)     # SM_CYSCREEN
        nx = int(round(pt.x + dx))
        ny = int(round(pt.y + dy))
        if w > 0 and h > 0:
            nx = min(max(nx, 0), w - 1)
            ny = min(max(ny, 0), h - 1)
        u.SetCursorPos(nx, ny)
    except Exception:           # noqa: BLE001
        return


def _x11_move_rel(dx: float, dy: float) -> None:
    """Linux 兜底：没有统一 warp API，退回 pyautogui（会被指针加速影响，
    但游戏模式本来就不在 Linux 上承诺）。函数内 import：没装 pyautogui
    的机器上这个模块照样能 import。"""
    try:
        import pyautogui

        pyautogui.moveRel(dx, dy, duration=0, _pause=False)
    except Exception:           # noqa: BLE001
        return


def move_rel(dx_px: float, dy_px: float) -> None:
    """按像素做「warp 语义」的相对位移（协议 §3 moverel）。

    位移量已经被控制端从归一化坐标（0.001 = 屏宽 0.1%）换算成像素；
    这里只负责「取当前位置 + 位移 → 夹到屏幕内 → warp」。
    """
    try:
        dx = float(dx_px)
        dy = float(dy_px)
    except (TypeError, ValueError):
        return
    if dx == 0 and dy == 0:
        return
    if SYSTEM == "Darwin":
        _mac_move_rel(dx, dy)
    elif SYSTEM == "Windows":
        _win_move_rel(dx, dy)
    else:
        _x11_move_rel(dx, dy)
