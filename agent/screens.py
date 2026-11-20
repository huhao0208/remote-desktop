"""显示器枚举（协议 v2 §3 的数据源）。

优先 mss；但 macOS 上「屏幕录制」授权缺失时 mss 的 CoreGraphics 显示器列表会
退化成 0×0（甚至 grab 卡 30s），而 Quartz 的 CGGetActiveDisplayList 仍能给出真实
尺寸，`screencapture` 也照常能截到图。所以这里加一层回落，避免把「mss 不可用」
误报成「没有显示器 / 没有授权」。

返回项字段：left/top/width/height（全局坐标，原点在主屏左上）、name、primary、source。
source = "mss" | "quartz"，上层据此决定抓屏后端（quartz → 用 screencapture/ImageGrab）。
"""
from __future__ import annotations

import platform

SYSTEM = platform.system()


def _via_mss() -> list:
    try:
        import mss

        sct = mss.MSS() if hasattr(mss, "MSS") else mss.mss()
    except Exception:
        return []
    try:
        return [dict(m) for m in sct.monitors[1:]
                if m["width"] > 0 and m["height"] > 0]
    except Exception:
        return []
    finally:
        try:
            sct.close()
        except Exception:
            pass


def _via_quartz() -> list:
    if SYSTEM != "Darwin":
        return []
    try:
        import Quartz

        ids = list(Quartz.CGGetActiveDisplayList(16, None, None)[1])
    except Exception:
        return []
    out = []
    for d in ids:
        try:
            r = Quartz.CGDisplayBounds(d)
            w, h = int(r.size.width), int(r.size.height)
        except Exception:
            continue
        if w <= 0 or h <= 0:
            continue
        out.append({"left": int(r.origin.x), "top": int(r.origin.y), "width": w, "height": h})
    return out


def _names(count: int) -> tuple:
    if SYSTEM == "Darwin":
        try:
            from AppKit import NSScreen

            screens = list(NSScreen.screens())
            if len(screens) == count:  # 数量对不上就不猜，避免张冠李戴
                return [str(s.localizedName()) for s in screens], 0
        except Exception:
            pass
    return [f"显示器 {i + 1}" for i in range(count)], 0


def list_monitors() -> list:
    mons, source = _via_mss(), "mss"
    if not mons:
        mons, source = _via_quartz(), "quartz"
    names, primary = _names(len(mons))
    return [{
        "left": m["left"],
        "top": m["top"],
        "width": m["width"],
        "height": m["height"],
        "name": names[i] if i < len(names) else f"显示器 {i + 1}",
        "primary": i == primary,
        "source": source,
    } for i, m in enumerate(mons)]