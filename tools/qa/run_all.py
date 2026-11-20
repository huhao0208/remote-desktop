"""run_all：qa 套件入口。

用法：
    .venv/bin/python tools/qa/run_all.py                      # 默认 webrtc，自动起服务端+Agent
    .venv/bin/python tools/qa/run_all.py --transport jpeg      # 跑兜底通路
    .venv/bin/python tools/qa/run_all.py --no-auto-env         # 复用已在跑的服务端/Agent
    .venv/bin/python tools/qa/run_all.py --only media,input
    .venv/bin/python tools/qa/run_all.py --json                # 只输出机器可读 JSON

退出码：0 = 无 FAIL（SKIP 不算失败）；1 = 有 FAIL 或环境起不来。
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import traceback
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.qa import test_clipboard, test_degrade, test_input, test_media, test_multiscreen
from tools.qa.env import Env, log_tail
from tools.qa.model import FAIL, Result, summarize

CASES: List[Tuple[str, Callable[..., Result], str]] = [
    ("media", test_media.run, "WebRTC 媒体面（首帧/fps/分辨率/RTT/丢帧）"),
    ("degrade", test_degrade.run, "JPEG 兜底通路"),
    ("input", test_input.run, "输入事件连发不报错"),
    ("clipboard", test_clipboard.run, "v2 剪贴板双向同步"),
    ("multiscreen", test_multiscreen.run, "v2 多屏 screens 契约"),
]
CASE_SECONDS = {"media": None, "degrade": 5, "input": 2, "clipboard": 4, "multiscreen": 4}

METRIC_ROWS = [
    ("first_frame_ms", "首帧(ms)"),
    ("avg_fps", "帧率(fps)"),
    ("avg_mbps", "码率(Mbps)"),
    ("width", "宽度(px)"),
    ("height", "高度(px)"),
    ("rtt_ms", "RTT(ms)"),
    ("jitter_buffer_ms", "抖动缓冲(ms)"),
    ("drop_rate", "丢帧率"),
    ("frames_received", "收帧数"),
    ("frames_dropped", "丢帧数"),
]


def _build_env(args: argparse.Namespace) -> Env:
    return Env(server=args.server, mobile=args.mobile,
               artifacts=Path(args.artifacts) if args.artifacts else None,
               agent_python=args.agent_python or None,
               agent_pythonpath=args.agent_pythonpath or None)


def _setup(env: Env, args: argparse.Namespace) -> List[str]:
    notes: List[str] = []
    env.keep_awake()
    if not args.auto_env:
        if not env.ping():
            raise RuntimeError("--no-auto-env 但服务端未就绪（先手动起 srv2/server.py，或去掉该参数）")
        notes.append("--no-auto-env：复用已运行的服务端/Agent")
        return notes
    env.start_server()
    # 必须在 Agent 启动前探测抓屏：Agent 自己的采集会占住同一条采集通道，
    # 并发探测会假性变成 30s（不是产品/权限问题）
    env.capture_seconds()

    expect = "webrtc" if args.transport == "webrtc" else "jpeg"
    existing = None
    try:
        existing = env.hello(timeout=3, screens_wait=0).get("hello")
    except Exception:
        existing = None
    if existing:
        same_name = (existing.get("name") or "") == env.DEVICE_NAME
        if same_name and existing.get("media") == expect:
            notes.append(f"复用已在线 Agent（{existing.get('name')} media={existing.get('media')}）")
            return notes
        notes.append(f"同账号存在其它 Agent（{existing.get('name')} media={existing.get('media')}），"
                     f"改为启动独立 {env.DEVICE_NAME}")
    env.start_agent(args.transport)
    notes.append(f"已启动服务端/Agent（transport={args.transport}）")
    return notes


def _fmt(v: Any) -> str:
    if v is None:
        return "-"
    if isinstance(v, float):
        return f"{v:.2f}".rstrip("0").rstrip(".")
    if isinstance(v, dict):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return json.dumps(v, ensure_ascii=False)
    return str(v)


def _metrics_table(results: List[Result]) -> str:
    cols = [r for r in results if r.status != "SKIP" and r.name in ("test_media", "test_degrade")]
    if not cols:
        return ""
    head = f"{'指标':<16}" + "".join(f"{r.name.replace('test_', ''):>16}" for r in cols)
    lines = [head, "-" * len(head)]
    for key, label in METRIC_ROWS:
        if not any(r.metrics.get(key) is not None for r in cols):
            continue
        lines.append(f"{label:<16}" + "".join(f"{_fmt(r.metrics.get(key)):>16}" for r in cols))
    return "\n".join(lines)


def _human(results: List[Result], env: Env, notes: List[str]) -> str:
    out = ["", "===== QA SUITE ====="]
    for n in notes:
        out.append(f"  · {n}")
    out.append(f"  · 产物目录 {env.run_dir}")
    out.append("")
    for r in results:
        out.append(r.human())
    table = _metrics_table(results)
    if table:
        out.extend(["", "----- 实测数字 -----", table])
    s = summarize(results)
    out.append("")
    out.append(f"PASS {s['pass']} · FAIL {s['fail']} · SKIP {s['skip']} · exit={s['exit_code']}")
    return "\n".join(out)


def main(argv: Optional[List[str]] = None, only: Optional[List[str]] = None,
         single: Optional[str] = None) -> int:
    ap = argparse.ArgumentParser(description="远程桌面 WebRTC/JPEG 自动化验收套件")
    ap.add_argument("--server", default="http://127.0.0.1:8443")
    ap.add_argument("--mobile", default="13900000001")
    ap.add_argument("--transport", choices=["webrtc", "jpeg"], default="webrtc")
    ap.add_argument("--seconds", type=int, default=8, help="媒体稳定期采样时长")
    ap.add_argument("--only", default="", help="逗号分隔：media,degrade,input,clipboard,multiscreen")
    ap.add_argument("--json", nargs="?", const="-", default=None,
                    help="输出 JSON：给路径写文件，留空写 stdout")
    ap.add_argument("--artifacts", default="", help="产物目录（默认 tools/qa/.artifacts）")
    ap.add_argument("--no-auto-env", action="store_true", help="不自动拉起服务端/Agent")
    ap.add_argument("--agent-python", default="",
                    help="Agent 用的解释器（默认 .venv/bin/python）；屏幕录制授权按该可执行文件给")
    ap.add_argument("--agent-pythonpath", default="",
                    help="仅注入给 Agent 子进程的 PYTHONPATH（配合 --agent-python 用）")
    args = ap.parse_args(argv)
    args.auto_env = not args.no_auto_env

    picked = only or [k.strip() for k in args.only.split(",") if k.strip()] or [c[0] for c in CASES]
    cases = [c for c in CASES if c[0] in picked]
    if single:
        cases = [c for c in CASES if c[0] == single]

    env = _build_env(args)
    notes: List[str] = []
    results: List[Result] = []
    fatal: Optional[str] = None
    started = time.time()
    try:
        notes = _setup(env, args)
        for key, fn, _desc in cases:
            secs = args.seconds if CASE_SECONDS.get(key) is None else CASE_SECONDS[key]
            try:
                r = fn(env, seconds=secs)
            except Exception as e:
                r = Result(name=f"test_{key}", status=FAIL,
                           error=f"{type(e).__name__}: {e}")
                r.add("用例未抛异常", False, f"{type(e).__name__}: {e}")
                r.metrics["traceback"] = traceback.format_exc().splitlines()[-8:]
                r.finish()
            results.append(r)
            if args.json != "-":  # --json 到 stdout 时保持纯 JSON
                print(r.human(), flush=True)
    except Exception as e:
        fatal = f"{type(e).__name__}: {e}"
    finally:
        agent_tail = log_tail(env.agent_log, 15)
        env.close()

    s = summarize(results) if results else {"pass": 0, "fail": 0, "skip": 0, "total": 0,
                                            "exit_code": 1}
    if fatal and not results:
        s["exit_code"] = 1

    report: Dict[str, Any] = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "elapsed_s": round(time.time() - started, 1),
        "env": env.snapshot(),
        "transport": args.transport,
        "notes": notes,
        "fatal": fatal,
        "summary": s,
        "results": [r.as_dict() for r in results],
        "agent_log_tail": agent_tail.splitlines() if agent_tail else [],
    }

    out_path = None
    if args.json:
        if args.json == "-":
            print(json.dumps(report, ensure_ascii=False, indent=2))
        else:
            out_path = Path(args.json)
            out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    else:
        out_path = env.run_dir / "report.json"
        out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    if args.json != "-":
        print(_human(results, env, notes))
        if fatal:
            print(f"\n[FATAL] {fatal}")
        if out_path:
            print(f"\nJSON 报告：{out_path}")

    return int(s["exit_code"])


def run_single(fn: Callable[..., Result], name: str) -> int:
    return main(only=[name.replace("test_", "")], single=name.replace("test_", ""))


if __name__ == "__main__":
    sys.exit(main())