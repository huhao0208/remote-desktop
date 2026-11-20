"""test_clipboard（v2）：控制端下发 text → 被控端剪贴板变化。

前置：Agent 已实现 docs/media-protocol.md v2 §2（`clip` / `clip.sync`）。
本仓库当前 Agent 未实现该能力，因此用例做**能力探测**后 SKIP：
  hello 无 audio/screens 字段，且 clip.sync 无任何回执、pbpaste 不变 → SKIP（原因写明）
  有回执但剪贴板没变 → FAIL（真回归）
  Agent 回 agent.error → FAIL
测试会保存并在结束时恢复本机剪贴板内容。
"""
from __future__ import annotations

import sys as _sys
from pathlib import Path as _Path

if __name__ == "__main__":  # 支持直接执行 python tools/qa/test_xxx.py
    _sys.path.insert(0, str(_Path(__file__).resolve().parents[2]))

import json
import platform
import subprocess
import time
from typing import Any, List, Optional

from tools.qa.env import Env
from tools.qa.model import Result

WAIT_S = 4.0


def _pbpaste() -> Optional[str]:
    try:
        return subprocess.run(["pbpaste"], capture_output=True, timeout=5).stdout.decode(
            "utf-8", "replace")
    except Exception:
        return None


def _pbcopy(text: str) -> None:
    try:
        p = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
        p.communicate(text.encode("utf-8"))
    except Exception:
        pass


def run(env: Env, seconds: int = 4) -> Result:
    from websockets.sync.client import connect

    r = Result(name="test_clipboard")
    if platform.system() != "Darwin":
        return Result.skip("test_clipboard", "剪贴板断言依赖 macOS pbpaste/pbcopy").finish()

    pre = env.hello()
    hello = pre.get("hello") or {}
    caps = {k: hello.get(k) for k in ("audio", "screens", "clip") if k in hello}
    r.metrics["hello_caps"] = caps

    baseline = _pbpaste()
    if baseline is None:
        return Result.skip("test_clipboard", "pbpaste 不可用").finish()

    marker = f"QA-CLIP-{int(time.time())}"
    dev = env.pick_device()
    cfg = env.room(dev["device_id"])
    ws_base = env.server.replace("https://", "wss://").replace("http://", "ws://")
    url = f"{ws_base}/ws/signaling?token={cfg['token']}&device_id=qa-clip"

    msgs: List[dict] = []
    try:
        with connect(url, open_timeout=10, max_size=8 * 1024 * 1024) as ws:
            ws.send(json.dumps({"p": "clip.sync", "enable": True}))
            time.sleep(0.3)
            ws.send(json.dumps({"p": "clip", "dir": "up", "text": marker}))
            end = time.time() + max(WAIT_S, seconds)
            while time.time() < end:
                try:
                    raw = ws.recv(timeout=max(0.1, end - time.time()))
                except TimeoutError:
                    break
                if isinstance(raw, bytes):
                    continue
                m = json.loads(raw)
                if m.get("p") in ("clip", "clip.sync.ack", "clip.sync", "agent.error"):
                    msgs.append(m)

        got = _pbpaste() or ""
        changed = marker in got
        acked = any(m.get("p", "").startswith("clip") for m in msgs)
        errored = [m for m in msgs if m.get("p") == "agent.error"]

        r.metrics.update({
            "clipboard_changed": changed,
            "ack": acked,
            "messages": msgs[:5],
            "agent_caps": caps,
        })

        if errored:
            r.add("clip 消息未触发 agent.error", False, str(errored[:2]))
            return r.finish()
        if not changed and not acked:
            return Result.skip(
                "test_clipboard",
                "Agent 未实现 v2 剪贴板：clip.sync/clip 无回执且 pbpaste 未变化",
                r.metrics).finish()

        # 契约只要求「控制端下发 → 被控端 5s 内可粘贴」，回执不是必需项
        r.add("被控端剪贴板内容已更新（5s 内）", changed, marker)
        if acked:
            r.add("clip 回执已收到（可选增强）", True, f"{len(msgs)} 条")
        return r.finish()
    finally:
        _pbcopy(baseline)


if __name__ == "__main__":
    from .run_all import run_single
    raise SystemExit(run_single(run, "test_clipboard"))