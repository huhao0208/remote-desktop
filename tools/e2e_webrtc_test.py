#!/usr/bin/env python3
"""WebRTC 媒体链路实测：真实 Chrome + 控制页 + Agent。

约束（CDP 代理的实现限制）：
- `/eval` 只接受**单行** JS，且不能返回 Promise（会 unserializable）
- 因此所有异步操作都「先落全局变量，再轮询读取」

测三件事：
  1. 首帧时延（offer 发出 → 第一帧上屏）
  2. 稳定期帧率 / 码率 / 分辨率 / RTT / 抖动缓冲
  3. 输入通路是否仍然可用（WS 信令未被媒体占用）

用法：
    python tools/e2e_webrtc_test.py --mobile 13900000001 --seconds 8
前置：本地服务端 8443、Agent 以 --transport webrtc 运行、Chrome 开 CDP 代理 3456。
"""
from __future__ import annotations

import argparse
import json
import time
import urllib.parse
import urllib.request

PROXY = "http://127.0.0.1:3456"


def _get(path: str) -> dict:
    with urllib.request.urlopen(PROXY + path, timeout=30) as r:
        return json.loads(r.read().decode())


def _eval(target: str, js: str):
    js = " ".join(js.split())  # 压成单行：代理不接受多行脚本
    req = urllib.request.Request(f"{PROXY}/eval?target={target}", data=js.encode())
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            out = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        raise RuntimeError(f"HTTP {e.code} :: {detail} :: js={js[:160]}") from None
    if "error" in out:
        raise RuntimeError(f"{out['error']} :: {js[:160]}")
    return out.get("value")


def _eval_json(target: str, js: str) -> dict:
    return json.loads(_eval(target, js))


def open_control(host: str) -> str:
    return _get("/new?url=" + urllib.parse.quote(f"{host}/control"))["targetId"]


def wait_for(fn, timeout: float, interval: float = 0.5) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        if fn():
            return True
        time.sleep(interval)
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="http://127.0.0.1:8443")
    ap.add_argument("--mobile", default="13900000001")
    ap.add_argument("--seconds", type=int, default=8)
    ap.add_argument("--target", help="复用已有 tab（不给则新开）")
    args = ap.parse_args()

    tid = args.target or open_control(args.host)
    print(f"[test] target={tid}")
    # 等页面脚本真正就绪（新 tab 的 load 事件早于内联脚本初始化）
    ready = wait_for(lambda: _eval(tid, "typeof doLogin") == "function", 20)
    if not ready:
        print("[FAIL] 页面脚本未就绪")
        return 1

    # 1. 登录（无 token 时）
    st = _eval_json(tid, "JSON.stringify({logged:!!localStorage.getItem('rd_token')})")
    print(f"[test] 初始状态 {st}")
    if not st["logged"]:
        _eval(tid, f"(()=>{{window.__login='pending';doLogin('{args.mobile}')"
                   f".then(r=>window.__login='ok').catch(e=>window.__login='err:'+e.message);"
                   f"return 'started'}})()")
        ok = wait_for(lambda: _eval(tid, "window.__login") != "pending", 15)
        print(f"[test] 登录 {_eval(tid, 'window.__login')} (wait={ok})")

    # 2. 等设备列表出现可控行
    ok = wait_for(lambda: "ok" in str(_eval(tid, "(()=>{const d=document.querySelectorAll('.dev.clickable');"
                                                 "return d.length?'ok:'+d.length:'no'})()")), 15)
    if not ok:
        print("[FAIL] 没有可控设备：确认 Agent 以 --transport webrtc 在线")
        print(_eval(tid, "document.getElementById('devList').innerText"))
        return 1

    # 3. 进入设备（点击后异步协商，结果不阻塞）
    _eval(tid, "(()=>{document.querySelectorAll('.dev.clickable')[0].click();return 'clicked'})()")
    print("[test] 已点击设备，等待 WebRTC 协商…")

    # CDP 代理对长脚本不稳（会返回 Uncaught），拆成多条短脚本分别取
    JS_MEDIA = "JSON.stringify({on:rtcOn,st:rtcState,mbps:Math.round((rtcMbps||0)*10)/10,rtt:rtcRtt})"
    JS_STATS = "JSON.stringify({fps:rtcStats.fps||0,w:rtcStats.w||0,h:rtcStats.h||0,jb:(rtcStats.jb===undefined?null:rtcStats.jb),drop:rtcStats.dropped||0})"
    JS_VIEW = "JSON.stringify({hud:document.getElementById('hud').textContent,vw:document.getElementById('vid').videoWidth,vh:document.getElementById('vid').videoHeight})"

    rtcf, rtco = 0, 0
    samples, first_frame, media = [], None, None
    for i in range(args.seconds):
        time.sleep(1)
        a, b, c = (_eval_json(tid, JS_MEDIA), _eval_json(tid, JS_STATS), _eval_json(tid, JS_VIEW))
        s = {"rtcOn": a["on"], "state": a["st"], "mbps": a["mbps"], "rtt": a.get("rtt"),
             "fps": b["fps"], "w": b["w"], "h": b["h"], "jb": b.get("jb"), "dropped": b["drop"],
             "hud": c["hud"], "videoW": c["vw"], "videoH": c["vh"],
             "firstFrame": rtcf, "offerAt": rtco}
        try:
            tf = _eval_json(tid, "JSON.stringify({f:rtcFirstFrame||0,o:rtcOfferAt||0})")
            rtcf, rtco = tf["f"], tf["o"]
            s["firstFrame"], s["offerAt"] = rtcf, rtco
        except Exception:
            pass
        if first_frame is None and s["firstFrame"] and s["offerAt"]:
            first_frame = s["firstFrame"] - s["offerAt"]
        if s["w"]:
            media = f"{s['w']}x{s['h']}"
        samples.append(s)
        print(f"[{i+1:02d}] hud={s['hud']}")
        print(f"     state={s['state']} {s['fps']}fps {s['mbps']:.1f}Mbps "
              f"rtt={s['rtt']}ms jb={s['jb']}ms drop={s['dropped']} video={s['videoW']}x{s['videoH']}")

    # 4. 输入通路验证
    _eval(tid, r"""(()=>{const st=document.getElementById('stage');const t=new Touch({identifier:1,target:st,clientX:300,clientY:300});st.dispatchEvent(new TouchEvent('touchstart',{touches:[t],changedTouches:[t],bubbles:true,cancelable:true}));st.dispatchEvent(new TouchEvent('touchend',{touches:[],changedTouches:[t],bubbles:true,cancelable:true}));return 'input-sent'})()""")

    good = [s for s in samples if s["fps"] > 0 and s["videoW"] > 0]
    summary = {
        "webrtc_ok": bool(good),
        "first_frame_ms": round(first_frame) if first_frame else None,
        "avg_fps": round(sum(s["fps"] for s in good) / len(good), 1) if good else 0,
        "avg_mbps": round(sum(s["mbps"] for s in good) / len(good), 2) if good else 0,
        "resolution": media,
        "rtt_ms": samples[-1]["rtt"],
        "jitter_buffer_ms": samples[-1]["jb"],
        "dropped_frames": samples[-1]["dropped"],
        "conn_state": samples[-1]["state"],
    }
    print("\n===== SUMMARY =====")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["webrtc_ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main())