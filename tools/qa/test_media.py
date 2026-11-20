"""test_media：WebRTC 媒体面硬指标（首帧 / 帧率 / 分辨率 / RTT / 丢帧率）。

判定阈值（契约 docs/media-protocol.md §3、§7）：
  首帧（点击设备 → 首个解码帧）< 1000 ms
  稳定期平均帧率 ≥ 10 fps
  分辨率 == stream.config.width（默认 1920，±2 容忍编码对齐）
  RTT < 100 ms
  丢帧率 < 5%（framesDropped / (framesReceived + framesDropped) 增量）

首帧口径：控制页的 rtcFirstFrame 在 `pc.ontrack` 就置位（远端轨建立，不代表已解出
画面），因此本用例以 `inbound-rtp.framesReceived > 0` 作为「真的有画面」的判定，
从点击设备开始计时（含建房间 / WS / offer-answer / ICE / 解码）。
Chrome 首次初始化 H.264 解码器时可能 > 1000ms，用例会重载控制页再测一次，
`cold_start_ms` 与 `first_frame_ms` 都记录，以预热后的结果判定。
"""
from __future__ import annotations

import sys as _sys
from pathlib import Path as _Path

if __name__ == "__main__":  # 支持直接执行 python tools/qa/test_xxx.py
    _sys.path.insert(0, str(_Path(__file__).resolve().parents[2]))

import json
import time
from collections import Counter
from typing import Any, Dict, List, Optional

from tools.qa.env import Env
from tools.qa.model import Result

CFG_WIDTH = 1920
FIRST_FRAME_LIMIT_MS = 1000
FPS_MIN = 10
RTT_LIMIT_MS = 100
DROP_RATE_LIMIT = 0.05
MAX_ATTEMPTS = 2

# 页内探针：每 100ms 把 inbound-rtp / candidate-pair 关键字段落到 window.__qa.samples。
# 约束：单行、同步返回；getStats 的 Promise 在回调里消化（代理不接受返回 Promise 的脚本）。
JS_POLLER = (
    "window.__qa={samples:[],t0:0};clearInterval(window.__qaTimer);"
    "window.__qaTimer=setInterval(()=>{if(typeof pc==='undefined'||!pc)return;"
    "pc.getStats().then(s=>{const o={t:Math.round(performance.now())};"
    "s.forEach(r=>{if(r.type==='inbound-rtp'&&r.kind==='video'){"
    "o.fr=r.framesReceived||0;o.fd=r.framesDropped||0;o.fps=r.framesPerSecond||0;"
    "o.w=r.frameWidth||0;o.h=r.frameHeight||0;o.br=r.bytesReceived||0;"
    "o.pli=r.pliCount||0;o.nack=r.nackCount||0;"
    "o.jb=(r.jitterBufferDelay!=null&&r.jitterBufferEmittedCount)?"
    "Math.round(r.jitterBufferDelay/r.jitterBufferEmittedCount*1000):null}"
    "if(r.type==='candidate-pair'&&r.state==='succeeded'&&r.nominated){"
    "o.rtt=Math.round((r.currentRoundTripTime||0)*1000)}});"
    "window.__qa.samples.push(o);if(window.__qa.samples.length>600)window.__qa.samples.shift()})},100);"
    "'ok'"
)

JS_CLICK = ("(()=>{const rows=[...document.querySelectorAll('.dev.clickable')];"
            "const el=rows.find(e=>e.textContent.includes('QA-PC'));"
            "if(!el)return 'none';el.click();return 'clicked'})()")

JS_FIRST_FRAME = ("(()=>{const q=window.__qa;if(!q||!q.samples.length)return -1;"
                  "for(const s of q.samples){if(s.fr>0)return Math.round(s.t-q.t0)}return -1})()")

JS_PAGE_STATE = (
    "JSON.stringify({on:rtcOn,st:rtcState,hud:document.getElementById('hud').textContent,"
    "vw:vid.videoWidth,vh:vid.videoHeight,disp:getComputedStyle(vid).display,"
    "ff:rtcFirstFrame,oa:rtcOfferAt,t0:window.__qa.t0})"
)


def _pct(x: float) -> str:
    return f"{x * 100:.1f}%"


def _series(samples: List[dict]) -> List[dict]:
    return [s for s in samples if s.get("fr", 0) > 0]


def _attempt(env: Env, tid: str, seconds: int) -> Optional[Dict[str, Any]]:
    """在设备列表页点开设备并采样一次。"""
    c = env.browser()
    if not c.wait_for(tid, "document.querySelectorAll('.dev.clickable').length>0", 20):
        return None
    c.eval(tid, JS_POLLER)
    c.eval(tid, "window.__qa.t0=performance.now();'ok'")
    if c.eval(tid, JS_CLICK) == "none":
        return None

    first_frame = None
    abort = None
    seen_on = False
    started_at = time.time()
    deadline = started_at + 15
    while time.time() < deadline:
        ff = c.eval(tid, JS_FIRST_FRAME)
        if isinstance(ff, (int, float)) and ff >= 0:
            first_frame = int(ff)
            break
        on = c.eval(tid, "rtcOn") is True
        seen_on = seen_on or on
        if seen_on and not on:  # startRTC 后被 stopRTC：协商失败回落 JPEG
            abort = "rtc_failed_回落到JPEG"
            break
        if not seen_on and time.time() - started_at > 4:
            abort = "rtc_not_started（hello.media 非 webrtc 或页面未触发 startRTC）"
            break
        if c.eval(tid, "rtcState") in ("failed", "closed"):
            abort = "connectionState=" + str(c.eval(tid, "rtcState"))
            break
        time.sleep(0.1)

    time.sleep(max(2, seconds))
    samples = json.loads(c.eval(tid, "JSON.stringify(window.__qa.samples)"))
    state = c.eval_json(tid, JS_PAGE_STATE)
    return {"first_frame_ms": first_frame, "samples": samples, "state": state, "abort": abort}


def _reload(env: Env, tid: str) -> None:
    c = env.browser()
    c.navigate(tid, env.server + "/control")
    if not c.wait_for(tid, "typeof doLogin === 'function'", 20):
        raise RuntimeError("重载控制页失败")
    c.wait_for(tid, "document.querySelectorAll('.dev.clickable').length>0", 20)


def _analyze(att: Dict[str, Any]) -> Dict[str, Any]:
    samples: List[dict] = att["samples"]
    state: Dict[str, Any] = att["state"]
    live = _series(samples)
    tail = live[len(live) // 3:] or live
    avg_fps = round(sum(s.get("fps", 0) for s in tail) / len(tail), 1) if tail else 0

    if len(live) >= 2:
        a, b = live[0], live[-1]
        dt = (b["t"] - a["t"]) / 1000
        avg_mbps = round(max(0.0, (b["br"] - a["br"]) * 8 / 1e6 / dt), 2) if dt > 0 else 0
        dfr, dfd = b["fr"] - a["fr"], b["fd"] - a["fd"]
        drop_rate = dfd / (dfr + dfd) if (dfr + dfd) > 0 else 0.0
    else:
        avg_mbps, drop_rate, dfr, dfd = 0.0, 1.0, 0, 0

    res = Counter((s["w"], s["h"]) for s in live if s.get("w"))
    width, height = res.most_common(1)[0][0] if res else (0, 0)
    rtts = [s["rtt"] for s in samples if s.get("rtt") is not None]
    jbs = [s["jb"] for s in samples if s.get("jb") is not None]

    return {
        "first_frame_ms": att["first_frame_ms"],
        "abort": att.get("abort"),
        "avg_fps": avg_fps,
        "avg_mbps": avg_mbps,
        "width": width,
        "height": height,
        "rtt_ms": rtts[-1] if rtts else None,
        "jitter_buffer_ms": jbs[-1] if jbs else None,
        "frames_received": dfr,
        "frames_dropped": dfd,
        "drop_rate": round(drop_rate, 4),
        "pli": live[-1].get("pli") if live else None,
        "rtc_ontrack_ms": (round(state["ff"] - state["oa"])
                           if state.get("ff") and state.get("oa") else None),
        "click_to_offer_ms": (round(state["oa"] - state["t0"])
                              if state.get("oa") and state.get("t0") else None),
        "conn_state": state.get("st"),
        "hud": state.get("hud"),
        "video_size": f"{state.get('vw')}x{state.get('vh')}",
        "on": bool(state.get("on")),
        "video_display": state.get("disp"),
    }


def run(env: Env, seconds: int = 8) -> Result:
    r = Result(name="test_media")

    pre = env.hello()
    hello = pre.get("hello") or {}
    media = hello.get("media", "jpeg")
    r.metrics["agent_media"] = media
    r.metrics["agent_name"] = hello.get("name")
    r.metrics["agent_screen"] = hello.get("screen")
    if media != "webrtc":
        return Result.skip("test_media",
                           f"Agent 当前 media={media}（未走 WebRTC，--transport jpeg 模式）",
                           r.metrics).finish()

    r.metrics["capture_s"] = env.capture_seconds()
    blocked = env.capture_block_reason()
    if blocked:
        return Result.skip("test_media", blocked, r.metrics).finish()

    tid = env.open_control()
    c = env.browser()
    try:
        if not c.wait_for(tid, "document.querySelectorAll('.dev.clickable').length>0", 20):
            r.error = "设备列表无可点击设备（Agent 是否在线？）"
            r.add("设备列表出现可控 Agent", False, "agent offline")
            return r.finish()

        attempts: List[Dict[str, Any]] = []
        for i in range(MAX_ATTEMPTS):
            att = _attempt(env, tid, seconds)
            if att is None:
                r.error = "点击设备后未建立测量会话"
                r.add("点击设备进入桌面", False, "no session")
                return r.finish()
            a = _analyze(att)
            attempts.append(a)
            if a.get("abort"):
                if i + 1 < MAX_ATTEMPTS:
                    _reload(env, tid)
                    continue
                r.error = f"WebRTC 未建立：{a['abort']}"
                break
            ok_first = (a["first_frame_ms"] is not None
                        and a["first_frame_ms"] < FIRST_FRAME_LIMIT_MS)
            if ok_first:
                break
            if i + 1 < MAX_ATTEMPTS:  # 冷启动重试一次：重载控制页，重置解码器
                _reload(env, tid)

        best = attempts[-1]
        r.metrics.update(best)
        r.metrics["cold_start_ms"] = attempts[0]["first_frame_ms"]
        r.metrics["attempts"] = len(attempts)

        shot = env.run_dir / "media.png"
        try:
            shot.write_bytes(c.screenshot(tid))
        except Exception:
            pass
        r.metrics["screenshot"] = str(shot)

        warm_note = (f"首次 {attempts[0]['first_frame_ms']} ms（冷启动），"
                     f"复测 {best['first_frame_ms']} ms") if len(attempts) > 1 else ""
        r.add("媒体来自 WebRTC（<video> 上屏 + HUD 显示 H.264）",
              best["on"] and best["video_display"] != "none" and "H.264" in (best["hud"] or ""),
              f"on={best['on']} display={best['video_display']} hud={best['hud']}")
        r.add("video 元素有真实解码尺寸",
              all(int(x) > 0 for x in best["video_size"].split("x")), best["video_size"])
        r.add(f"首帧 < {FIRST_FRAME_LIMIT_MS} ms",
              best["first_frame_ms"] is not None and best["first_frame_ms"] < FIRST_FRAME_LIMIT_MS,
              f"{best['first_frame_ms']} ms" + (f"（{warm_note}）" if warm_note else ""),
              best["first_frame_ms"], FIRST_FRAME_LIMIT_MS)
        r.add(f"平均帧率 ≥ {FPS_MIN} fps", best["avg_fps"] >= FPS_MIN,
              f"{best['avg_fps']} fps", best["avg_fps"], FPS_MIN)
        r.add(f"分辨率 == stream.config.width ({CFG_WIDTH})",
              abs(best["width"] - CFG_WIDTH) <= 2 and best["height"] > 0,
              f"{best['width']}x{best['height']}", best["width"], CFG_WIDTH)
        r.add(f"RTT < {RTT_LIMIT_MS} ms",
              best["rtt_ms"] is not None and best["rtt_ms"] < RTT_LIMIT_MS,
              f"{best['rtt_ms']} ms", best["rtt_ms"], RTT_LIMIT_MS)
        r.add(f"丢帧率 < {_pct(DROP_RATE_LIMIT)}", best["drop_rate"] < DROP_RATE_LIMIT,
              f"{_pct(best['drop_rate'])}（{best['frames_dropped']}/"
              f"{best['frames_received'] + best['frames_dropped']}）",
              best["drop_rate"], DROP_RATE_LIMIT)
        return r.finish()
    finally:
        env.close_tab(tid)


if __name__ == "__main__":
    from tools.qa.run_all import run_single
    raise SystemExit(run_single(run, "test_media"))