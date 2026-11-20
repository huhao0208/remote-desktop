"""test_multiscreen（v2）：`screens` 消息结构校验 + 多屏切换。

判定：
  未收到 screens → SKIP（Agent 未实现 v2 多屏）
  结构不合契约 → FAIL（缺字段 / 类型不对）
  只有 1 屏 → SKIP（结构校验通过，但无第二块屏可切）
  ≥2 屏 → PASS，并校验 screen.select → screen.selected 往返
"""
from __future__ import annotations

import sys as _sys
from pathlib import Path as _Path

if __name__ == "__main__":  # 支持直接执行 python tools/qa/test_xxx.py
    _sys.path.insert(0, str(_Path(__file__).resolve().parents[2]))

import json
import time
from typing import Any, Dict, List

from tools.qa.env import Env
from tools.qa.model import Result

REQUIRED = {"id": int, "w": int, "h": int, "x": int, "y": int, "name": str, "primary": bool}


def _validate(msg: dict) -> List[str]:
    errs: List[str] = []
    if not isinstance(msg.get("current"), int):
        errs.append("current 应为 int")
    lst = msg.get("list")
    if not isinstance(lst, list) or not lst:
        errs.append("list 应为非空数组")
        return errs
    if isinstance(msg.get("current"), int) and not (0 <= msg["current"] < len(lst)):
        errs.append("current 越界")
    for i, s in enumerate(lst):
        if not isinstance(s, dict):
            errs.append(f"list[{i}] 不是对象")
            continue
        for k, t in REQUIRED.items():
            if k not in s:
                errs.append(f"list[{i}] 缺 {k}")
            elif not isinstance(s[k], t):
                errs.append(f"list[{i}].{k} 类型应为 {t.__name__}")
        if isinstance(s.get("w"), int) and s["w"] <= 0:
            errs.append(f"list[{i}].w 应为正数")
    if not any(s.get("primary") for s in lst if isinstance(s, dict)):
        errs.append("缺少 primary=true 的屏")
    return errs


def run(env: Env, seconds: int = 4) -> Result:
    from websockets.sync.client import connect

    r = Result(name="test_multiscreen")
    pre = env.hello()
    hello = pre.get("hello") or {}
    screens: Dict[str, Any] = pre.get("screens") or {}

    local_monitors = env._monitor_count()
    r.metrics["local_monitors"] = local_monitors
    r.metrics["hello_screens"] = hello.get("screens")
    r.metrics["screens_msg"] = screens or None

    if not screens:
        declared = hello.get("screens")
        if isinstance(declared, int):
            if declared <= 0:
                return Result.skip(
                    "test_multiscreen",
                    f"显示器枚举为空（hello.screens=0，本机 mss 枚举 {local_monitors} 屏），"
                    f"疑似同「屏幕录制」授权问题；多屏结构无法校验",
                    r.metrics).finish()
            # Agent 只在启动时广播一次 screens 消息，晚加入的控制端收不到；
            # 此时只能依据 hello.screens 声明的数量判断适用性
            return Result.skip(
                "test_multiscreen",
                f"hello.screens={declared}（本机显示器 {local_monitors}），单屏无切换场景；"
                f"screens 消息仅在 Agent 启动时广播，晚加入收不到，结构校验待多屏环境补测",
                r.metrics).finish()
        return Result.skip(
            "test_multiscreen",
            "Agent 未实现 v2 多屏：hello 无 screens 字段，且等待窗口内未收到 screens 消息",
            r.metrics).finish()

    errs = _validate(screens)
    r.add("screens 消息结构符合契约", not errs, "; ".join(errs) if errs else "ok")
    if errs:
        return r.finish()

    lst = screens["list"]
    r.metrics["screen_count"] = len(lst)
    r.metrics["screens"] = [{"id": s["id"], "res": f"{s['w']}x{s['h']}", "primary": s["primary"]}
                            for s in lst]

    if len(lst) < 2 or local_monitors == 1:
        return Result.skip(
            "test_multiscreen",
            f"只有 {len(lst)} 屏（本机显示器 {local_monitors}），多屏切换用例不适用；结构校验已通过",
            r.metrics).finish()

    # 切换往返
    target = next(s["id"] for s in lst if s["id"] != screens["current"])
    dev = env.pick_device()
    cfg = env.room(dev["device_id"])
    ws_base = env.server.replace("https://", "wss://").replace("http://", "ws://")
    url = f"{ws_base}/ws/signaling?token={cfg['token']}&device_id=qa-screen"
    selected = None
    with connect(url, open_timeout=10, max_size=8 * 1024 * 1024) as ws:
        ws.send(json.dumps({"p": "screen.select", "id": target}))
        end = time.time() + max(2, seconds)
        while time.time() < end:
            try:
                raw = ws.recv(timeout=max(0.1, end - time.time()))
            except TimeoutError:
                break
            if isinstance(raw, bytes):
                continue
            m = json.loads(raw)
            if m.get("p") == "screen.selected":
                selected = m.get("id")
                break
    r.metrics["selected"] = selected
    r.add("多屏切换 screen.select → screen.selected", selected == target,
          f"requested={target} got={selected}")
    return r.finish()


if __name__ == "__main__":
    from .run_all import run_single
    raise SystemExit(run_single(run, "test_multiscreen"))