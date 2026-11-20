#!/usr/bin/env python3
"""WebRTC 媒体链路实测（薄封装，保留旧入口）。

实际逻辑在 tools/qa/test_media.py，本脚本只做参数映射，退出码保持不变：
  0 = PASS，1 = FAIL，2 = SKIP（媒体面不适用）

用法：
    .venv/bin/python tools/e2e_webrtc_test.py --seconds 8
前置：服务端 8443 在跑；Agent 以 --transport webrtc 在线（或由 --auto-env 拉起）。
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools.qa import run_all  # noqa: E402
from tools.qa.env import Env  # noqa: E402
from tools.qa.model import Result, summarize  # noqa: E402
from tools.qa import test_media  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", "--server", dest="server", default="http://127.0.0.1:8443")
    ap.add_argument("--mobile", default="13900000001")
    ap.add_argument("--seconds", type=int, default=8)
    ap.add_argument("--no-auto-env", action="store_true", help="复用已在跑的 Agent")
    a = ap.parse_args()

    env = Env(server=a.server, mobile=a.mobile)
    try:
        if not a.no_auto_env:
            env.start_server()
            try:
                env.hello(timeout=2)
            except Exception:
                env.start_agent("webrtc")
        r = test_media.run(env, seconds=a.seconds)
    finally:
        env.close()

    print(r.human())
    s = summarize([r])
    if r.status == "SKIP":
        return 2
    return int(s["exit_code"])


if __name__ == "__main__":
    raise SystemExit(main())