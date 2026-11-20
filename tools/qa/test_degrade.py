"""test_degrade：JPEG 兜底通路不回归（Agent --transport jpeg）。

判定：
  Agent hello.media == "jpeg"（否则本用例 SKIP，属 webrtc 模式不适用）
  控制页仍走 canvas 渲染（<video> 隐藏、canvas 可见）
  JPEG 帧持续到达：平均 fps ≥ 5、最近一帧年龄 < 2000 ms
  截图非纯黑（平均亮度 > 2，排除「HUD 在动但画面全黑」的假绿）
"""
from __future__ import annotations

import sys as _sys
from pathlib import Path as _Path

if __name__ == "__main__":  # 支持直接执行 python tools/qa/test_xxx.py
    _sys.path.insert(0, str(_Path(__file__).resolve().parents[2]))

import io
import time
from typing import List

from tools.qa.env import Env
from tools.qa.model import Result

FPS_MIN = 5
STALE_MS = 2000
BRIGHTNESS_MIN = 2.0

JS_SAMPLE = (
    "JSON.stringify({fps:fpsVal,sw:screenW,sh:screenH,"
    "hud:document.getElementById('hud').textContent,"
    "st:document.getElementById('status').textContent,"
    "vdisp:getComputedStyle(vid).display,cdisp:getComputedStyle(view).display,"
    "on:rtcOn,age:lastFrame?Math.round(Date.now()-lastFrame):-1,"
    "cw:view.width,ch:view.height})"
)

JS_CLICK = ("(()=>{const rows=[...document.querySelectorAll('.dev.clickable')];"
            "const el=rows.find(e=>e.textContent.includes('QA-PC'));"
            "if(!el)return 'none';el.click();return 'clicked'})()")


def _brightness(png: bytes) -> float:
    from PIL import Image
    img = Image.open(io.BytesIO(png)).convert("L")
    img = img.resize((64, 64))
    px = list(img.getdata())
    return round(sum(px) / len(px), 2)


def run(env: Env, seconds: int = 5) -> Result:
    r = Result(name="test_degrade")
    hello = (env.hello().get("hello") or {})
    media = hello.get("media", "jpeg")
    r.metrics["agent_media"] = media
    if media != "jpeg":
        return Result.skip("test_degrade",
                           f"Agent media={media}；兜底通路用例仅覆盖 --transport jpeg，"
                           f"用 run_all.py --transport jpeg 运行",
                           r.metrics).finish()

    r.metrics["capture_s"] = env.capture_seconds()
    blocked = env.capture_block_reason()
    if blocked:
        return Result.skip("test_degrade", blocked, r.metrics).finish()

    tid = env.open_control()
    c = env.browser()
    try:
        if not c.wait_for(tid, "document.querySelectorAll('.dev.clickable').length>0", 20):
            r.error = "设备列表无可点击设备"
            return r.finish()
        if c.eval(tid, JS_CLICK) == "none":
            r.error = "列表中没有 QA-PC"
            return r.finish()
        if not c.wait_for(tid, "document.getElementById('stage').style.display==='block'", 15):
            r.error = "未进入桌面（WS 未连上）"
            return r.finish()

        time.sleep(1.5)  # 等首帧（JPEG 首帧有 8B 时戳，解码异步）
        samples: List[dict] = []
        for _ in range(max(2, seconds)):
            time.sleep(1)
            samples.append(c.eval_json(tid, JS_SAMPLE))

        shot = env.run_dir / "degrade.png"
        png = c.screenshot(tid)
        shot.write_bytes(png)
        bright = _brightness(png)

        tail = samples[len(samples) // 2:] or samples
        avg_fps = round(sum(s["fps"] for s in tail) / len(tail), 1)
        last = samples[-1]
        r.metrics.update({
            "avg_fps": avg_fps,
            "screen": f"{last['sw']}x{last['sh']}",
            "frame_age_ms": last["age"],
            "brightness": bright,
            "hud": last["hud"],
            "screenshot": str(shot),
        })

        r.add("Agent 明确走 JPEG 通路", media == "jpeg", media)
        r.add("canvas 可见且 <video> 已隐藏",
              last["cdisp"] != "none" and last["vdisp"] == "none" and not last["on"],
              f"canvas={last['cdisp']} video={last['vdisp']} rtcOn={last['on']}")
        r.add(f"JPEG 帧率 ≥ {FPS_MIN} fps", avg_fps >= FPS_MIN, f"{avg_fps} fps", avg_fps, FPS_MIN)
        r.add(f"最近一帧 < {STALE_MS} ms", 0 <= last["age"] < STALE_MS, f"{last['age']} ms",
              last["age"], STALE_MS)
        r.add("截图非纯黑（有真实画面）", bright > BRIGHTNESS_MIN, f"亮度 {bright}", bright,
              BRIGHTNESS_MIN)
        return r.finish()
    finally:
        env.close_tab(tid)


if __name__ == "__main__":
    from .run_all import run_single
    raise SystemExit(run_single(run, "test_degrade"))