"""防窥遮罩窗（独立子进程）。

为什么是子进程：tkinter 的 `mainloop()` 会独占线程，而 agent 主线程在跑
asyncio 事件循环。塞进线程里在 macOS 上会直接崩（Tcl 不是线程安全的）。
所以 agent 用 `sys.executable --privacy-overlay ...` 另起一个进程，
状态靠进程存活与否表达——最简单也最不容易出错。

窗口行为对齐官方「防窥模式」：
- 黑屏防护：纯黑全屏置顶，遮住桌面内容；
- 隐私屏保：全屏置顶图片（自定义壁纸），遮住桌面内容；
- 被控端本地按 Esc 解除（官方「解除防窥快捷键」的最小实现）。

单独的显示器用独立窗口铺，坐标由父进程从 `list_monitors()` 取好后传进来——
这里不 import mss/screens，保持子进程启动足够快（<300ms）。

退出：Esc / SIGTERM / 父进程销毁（Windows 上 JD 无父子联动，靠 kill）。
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import sys

# 遮罩窗只能在主线程建，且必须先有 root
try:
    import tkinter as tk
except Exception as e:  # pragma: no cover - 只有精简 Python 才走到
    print(json.dumps({"ok": False, "err": f"tkinter 不可用：{e}"}), flush=True)
    raise SystemExit(2)


def _parse_screens(raw: str) -> list[tuple[int, int, int, int]]:
    """`x,y,w,h;x,y,w,h` → [(x,y,w,h)]；空串返回 []（由调用方退回主屏）。"""
    out: list[tuple[int, int, int, int]] = []
    for part in (raw or "").split(";"):
        part = part.strip()
        if not part:
            continue
        nums = part.split(",")
        if len(nums) != 4:
            continue
        try:
            out.append(tuple(int(float(n)) for n in nums))  # type: ignore[arg-type]
        except ValueError:
            continue
    return out


def _cover(path: str, w: int, h: int):
    """把壁纸裁成「铺满」尺寸（等比放大 + 居中裁剪），返回 PIL Image。"""
    from PIL import Image

    img = Image.open(path).convert("RGB")
    scale = max(w / img.width, h / img.height)
    nw, nh = max(1, round(img.width * scale)), max(1, round(img.height * scale))
    img = img.resize((nw, nh), Image.LANCZOS)
    left = (nw - w) // 2
    top = (nh - h) // 2
    return img.crop((left, top, left + w, top + h))


def _exclude_from_capture_win32(win) -> tuple[bool, str]:
    """Windows：`SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE=0x11)`（Win10 2004+）。"""
    try:
        import ctypes

        hwnd = int(win.winfo_id())
        # Tk 的 id 可能指向内层子窗，取根窗口（GA_ROOT=2）才吃得到这个属性
        root = ctypes.windll.user32.GetAncestor(hwnd, 2) or hwnd
        if ctypes.windll.user32.SetWindowDisplayAffinity(root, 0x11):
            return True, ""
        return False, f"SetWindowDisplayAffinity 失败（WinError {ctypes.get_last_error()}）"
    except Exception as e:  # noqa: BLE001
        return False, f"SetWindowDisplayAffinity 异常：{e}"


_OBJC_RT: dict | None = None
_OVERLAY_LEVEL = 25  # macOS：遮罩窗层级（见 _macos_lift_level）


def _objc_rt() -> dict:
    """懒加载 objc runtime + 各签名的 `objc_msgSend`。

    坑：`objc_msgSend` 是同一个函数指针，用 ctypes 直接给它设 argtypes 会互相覆盖
    （多返回值签名混用时会拿到垃圾指针甚至段错误）。这里用 CFUNCTYPE 派生独立签名。
    """
    global _OBJC_RT
    if _OBJC_RT is not None:
        return _OBJC_RT

    import ctypes
    import ctypes.util

    lib = ctypes.CDLL(ctypes.util.find_library("objc"))
    lib.objc_getClass.restype = ctypes.c_void_p
    lib.objc_getClass.argtypes = [ctypes.c_char_p]
    lib.sel_registerName.restype = ctypes.c_void_p
    lib.sel_registerName.argtypes = [ctypes.c_char_p]

    P, U = ctypes.c_void_p, ctypes.c_ulong
    addr = ctypes.cast(lib.objc_msgSend, ctypes.c_void_p).value

    def sel(name: str) -> int:
        return lib.sel_registerName(name.encode())

    # NSString → const char*（-UTF8String）
    send_cstr = ctypes.CFUNCTYPE(ctypes.c_char_p, P, P)(addr)
    _OBJC_RT = {
        "cls": lambda name: lib.objc_getClass(name.encode()),
        "sel": sel,
        "send_p": ctypes.CFUNCTYPE(P, P, P)(addr),          # -foo -> id
        "send_u": ctypes.CFUNCTYPE(U, P, P)(addr),          # -foo -> NSUInteger
        "send_p_u": ctypes.CFUNCTYPE(P, P, P, U)(addr),     # -foo:(NSUInteger) -> id
        "set_u": ctypes.CFUNCTYPE(None, P, P, U)(addr),     # -setFoo:(NSUInteger)
        "utf8": send_cstr,
    }
    return _OBJC_RT


def _ns_window_for(win) -> int:
    """Tk 窗口 → NSWindow*（按每窗唯一的 title 精确匹配）。"""
    o = _objc_rt()
    app = o["send_p"](o["cls"]("NSApplication"), o["sel"]("sharedApplication"))
    if not app:
        return 0
    arr = o["send_p"](app, o["sel"]("windows"))
    if not arr:
        return 0
    want = (win.title() or "").encode()
    for i in range(o["send_u"](arr, o["sel"]("count"))):
        w = o["send_p_u"](arr, o["sel"]("objectAtIndex:"), i)
        if not w:
            continue
        title = o["send_p"](w, o["sel"]("title"))
        got = o["utf8"](title, o["sel"]("UTF8String")) if title else None
        if got and got == want:
            return w
    return 0


def _macos_lift_level(win) -> int:
    """把遮罩窗提到普通窗口之上，返回实际生效的 level（失败返回 0）。

    实测：Tk 9 在 macOS 上 `attributes("-topmost", True)` **不改** NSWindow level
    （恒为 0），用户随便点一下自己的窗口，遮罩就被盖住了 —— 本地照样看得见内容。
    取 25（NSStatusWindowLevel）：盖得住普通窗口、Dock(20) 和菜单栏(24)，
    又不去碰屏保/锁屏那一层（1000+，那是系统自己的安全边界）。
    """
    try:
        o = _objc_rt()
        w = _ns_window_for(win)
        if not w:
            return 0
        o["set_u"](w, o["sel"]("setLevel:"), _OVERLAY_LEVEL)
        return int(o["send_u"](w, o["sel"]("level")))
    except Exception:  # noqa: BLE001
        return 0


def _exclude_from_capture_macos(win) -> tuple[bool, str]:
    """macOS：`NSWindow.sharingType = NSWindowSharingNone(0)`。

    实测（2026-11-21，macOS 15.8.1 / Tk 9.0 / 2048×1280，纯色遮罩 #101010）：
    - mss 走的 `CGWindowListCreateImage` 会把这个窗口从合成结果里剔掉
      （遮罩占比 70.4% → 0.2%，中心像素 #101010 → 桌面内容）；
    - `screencapture -l <win>` 在 sharingType=0 之后直接报 `could not create image from window`；
    - 但 ScreenCaptureKit 的窗口级截图会返回一张纯黑图，而不是桌面内容 ——
      真要走 SCK 的采集器（macOS 15 的 `screencapture` CLI 就链了 SCK）在整屏合成下
      是否也剔除本窗，本机锁屏状态下无法实测，见 security.py 的风险说明。

    必须在窗口已 order-in 之后调用：窗口没上屏时不在 `NSApp.windows` 里。
    """
    try:
        o = _objc_rt()
        w = _ns_window_for(win)
        if not w:
            return False, "找不到遮罩窗对应的 NSWindow（窗口可能还没上屏）"
        o["set_u"](w, o["sel"]("setSharingType:"), 0)
        now = o["send_u"](w, o["sel"]("sharingType"))
        if now != 0:
            return False, f"NSWindow.sharingType 设置未生效（当前 {now}）"
        return True, ""
    except Exception as e:  # noqa: BLE001
        return False, f"设置 NSWindow.sharingType 异常：{e}"


def _fail(payload: dict) -> None:
    """失败原因同时写 stdout 和 stderr。

    父进程把子进程 stdout 指向 DEVNULL、stderr 落日志，只写 stdout 的话，
    用户只能看到「退出码 4」，等于把原因吞了。
    """
    line = json.dumps(payload, ensure_ascii=False)
    print(line, flush=True)
    print(line, file=sys.stderr, flush=True)


def _exclude_from_capture(win) -> tuple[bool, str]:
    """让这个窗口「不进录屏」，返回 (ok, 失败原因)。

    这是整个防窥功能能成立的前提：遮罩窗一旦被采集进去，控制端看到的就是
    一块黑屏，功能直接废掉。失败必须报错而不是硬撑 —— 宁可不开防窥，
    也不能把控制端画面遮死。
    """
    if sys.platform == "win32":
        return _exclude_from_capture_win32(win)
    if sys.platform == "darwin":
        return _exclude_from_capture_macos(win)
    return False, f"{sys.platform} 上没有可用的『窗口不进录屏』接口"


def _ensure_tcl() -> None:
    """探测 Tcl/Tk 数据目录，补上 `TCL_LIBRARY` / `TK_LIBRARY`。

    踩过的坑：standalone 版 Python（uv / python-build-standalone）在 venv 里跑时，
    Tcl 只按 `sys.prefix` 找 `init.tcl`，而 venv 里没有这份数据，于是
    `tk.Tk()` 直接抛 `Cannot find a usable init.tcl`。PyInstaller 打包版由
    hook 设好这两个变量，这里兜住「源码直跑」和「解释器布局奇怪」两种场景。
    """
    if os.environ.get("TCL_LIBRARY") and os.path.isfile(
            os.path.join(os.environ["TCL_LIBRARY"], "init.tcl")):
        return

    roots: list[str] = []
    for r in (sys.base_prefix, sys.prefix,
              os.path.dirname(os.path.dirname(sys.executable)), "/usr/local", "/usr"):
        if r and r not in roots:
            roots.append(r)

    tcl_dir = tk_dir = ""
    for root in roots:
        # 常见布局：<prefix>/lib/tcl8.6、<prefix>/lib/tcl9.0、<prefix>/tcl/tcl8.6
        for libname in ("lib", "", "lib64"):
            base = os.path.join(root, libname) if libname else root
            try:
                entries = sorted(os.listdir(base), reverse=True)  # 9.0 优先于 8.6
            except OSError:
                continue
            for name in entries:
                cand = os.path.join(base, name)
                if not os.path.isdir(cand):
                    continue
                if not tcl_dir and (name.startswith("tcl8") or name.startswith("tcl9")
                                    or name == "_tcl_data") \
                        and os.path.isfile(os.path.join(cand, "init.tcl")):
                    tcl_dir = cand
                if not tk_dir and (name.startswith("tk8") or name.startswith("tk9")
                                   or name == "_tk_data"):
                    tk_dir = cand
        if tcl_dir:
            break
    if tcl_dir:
        os.environ["TCL_LIBRARY"] = tcl_dir
    if tk_dir:
        os.environ["TK_LIBRARY"] = tk_dir


def main(argv: list[str]) -> int:
    _ensure_tcl()
    ap = argparse.ArgumentParser(description="防窥遮罩窗")
    ap.add_argument("--mode", choices=["blank", "wallpaper"], default="blank")
    ap.add_argument("--image", default="")
    ap.add_argument("--screens", default="")
    ap.add_argument("--hint", default="被控端已开启防窥 · 按 Esc 解除")
    ap.add_argument("--exclude-capture", action="store_true",
                    help="要求窗口不进录屏（Windows: SetWindowDisplayAffinity；"
                         "macOS: NSWindow.sharingType=none；做不到就失败退出）")
    args = ap.parse_args(argv)

    root = tk.Tk()
    root.withdraw()
    # 根窗只是占位，真正的覆盖窗是 Toplevel，方便多屏各铺一个
    root.title("uu-privacy")

    screens = _parse_screens(args.screens)
    if not screens:
        screens = [(0, 0, root.winfo_screenwidth(), root.winfo_screenheight())]

    photo_cache: list[object] = []  # 必须持有引用，否则 PhotoImage 被 GC 后显示空白
    windows: list[tk.Toplevel] = []

    def close(*_args: object) -> None:
        try:
            root.quit()
            root.destroy()
        except Exception:
            pass

    for (x, y, w, h) in screens:
        win = tk.Toplevel(root)
        win.overrideredirect(True)
        win.geometry(f"{w}x{h}+{x}+{y}")
        win.configure(bg="black", cursor="none")
        try:
            win.attributes("-topmost", True)
        except Exception:
            pass
        holder = tk.Frame(win, bg="black", width=w, height=h)
        holder.pack(fill="both", expand=True)

        shown = False
        if args.mode == "wallpaper" and args.image and os.path.isfile(args.image):
            try:
                from PIL import ImageTk

                im = _cover(args.image, w, h)
                ph = ImageTk.PhotoImage(im)
                photo_cache.append(ph)
                tk.Label(holder, image=ph, bd=0, highlightthickness=0, bg="black").place(
                    x=0, y=0, relwidth=1, relheight=1)
                shown = True
            except Exception as e:
                print(json.dumps({"ok": False, "err": f"壁纸加载失败：{e}"}), flush=True)
                shown = False
        if not shown:
            tk.Label(holder, text="屏幕已被保护", fg="#2a2a2a", bg="black",
                     font=("Helvetica", max(16, min(w, h) // 18))).place(
                relx=0.5, rely=0.46, anchor="center")

        # 提示条：告诉本地用户「谁开的、怎么关」，避免以为死机
        tk.Label(holder, text=args.hint, fg="#6b6b6b", bg="black",
                 font=("Helvetica", 12)).place(relx=0.5, rely=0.96, anchor="center")

        win.bind("<Escape>", close)
        win.bind("<Button-1>", lambda _e: None)  # 吃掉点击，别把事件漏给桌面
        win.title(f"uu-privacy-{os.getpid()}-{len(windows)}")  # 唯一标记，macOS 靠它找 NSWindow
        win.update_idletasks()
        try:
            win.lift()
            win.focus_force()
        except Exception:
            pass
        windows.append(win)

        # Windows 的 HWND 在建窗时就有了，可以随建随设；
        # macOS 的 NSWindow 要等窗口真被 order-in 才进 NSApp.windows，统一放到后面
        if args.exclude_capture and sys.platform == "win32":
            ok, why = _exclude_from_capture(win)
            if not ok:
                # 遮不住采集就别装成功：否则控制端会看到全黑画面
                try:
                    close()
                except Exception:
                    pass
                _fail({
                    "ok": False,
                    "err": f"无法把遮罩窗排除出录屏（{why}），已放弃开启防窥",
                })
                return 4
    # 信号：父进程 terminate() 时干净退出，别留孤儿窗口
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, close)
        except Exception:
            pass

    # 把「真的映射到屏幕上了」这件事报给父进程：不起眼的自检，
    # 但在「窗口被系统吞掉」时比一句 ok 有用得多（macOS 上锁屏状态、缺权限都可能）
    maps: list[dict[str, int]] = []
    levels: list[int] = []
    try:
        root.update()
    except Exception:
        pass

    # macOS：窗口此刻已上屏，逐窗设 sharingType 并回读校验。
    # 这一步故意不裹在 try/except 里 —— 异常必须导致失败退出，
    # 绝不能悄悄放行一个「没排除出录屏」的遮罩。
    if args.exclude_capture and sys.platform == "darwin":
        for win in windows:
            levels.append(_macos_lift_level(win))
            ok, why = _exclude_from_capture(win)
            if not ok:
                try:
                    close()
                except Exception:
                    pass
                _fail({
                    "ok": False,
                    "err": f"无法把遮罩窗排除出录屏（{why}），已放弃开启防窥",
                })
                return 4

    try:
        for win in windows:
            maps.append({
                "mapped": int(bool(win.winfo_ismapped())),
                "w": int(win.winfo_width()),
                "h": int(win.winfo_height()),
                "x": int(win.winfo_rootx()),
                "y": int(win.winfo_rooty()),
            })
    except Exception:
        pass

    report: dict[str, object] = {"ok": True, "windows": len(windows), "mode": args.mode,
                                 "geometry": maps}
    if levels:
        report["level"] = levels  # macOS 遮罩窗层级（0 表示没提上去）
    print(json.dumps(report, ensure_ascii=False), flush=True)
    try:
        root.mainloop()
    except KeyboardInterrupt:
        close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
