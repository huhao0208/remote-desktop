"""test_input：输入事件连发时 Agent 不报错（信令 WS 与媒体面互不干扰）。

做法：以裸 WS 客户端进同一房间，连发 move / click / scroll / 修饰键，
断言：
  - 全程未收到 agent.error
  - 突发后 ping 仍收到 pong（Agent 主循环未卡死）
  - Agent 进程仍在、日志无 traceback / 断链
说明：click 落在屏幕右下角空白桌面，测试结束后恢复鼠标原位（不影响用户操作）。
"""
from __future__ import annotations

import sys as _sys
from pathlib import Path as _Path

if __name__ == "__main__":  # 支持直接执行 python tools/qa/test_xxx.py
    _sys.path.insert(0, str(_Path(__file__).resolve().parents[2]))

import json
import time
from typing import Any, Dict, List

from tools.qa.env import Env, log_tail
from tools.qa.model import Result

CLICK_POS = (0.995, 0.995)  # 右下角空白桌面，避免误触窗口/程序坞


def _events() -> List[dict]:
    evs: List[dict] = []
    for i in range(8):
        evs.append({"p": "input", "t": "move", "x": 0.2 + 0.07 * i, "y": 0.3 + 0.05 * i})
    for _ in range(3):
        evs.append({"p": "input", "t": "click", "btn": "left",
                    "x": CLICK_POS[0], "y": CLICK_POS[1]})
    for dy in (1, -1, 2, -2):
        evs.append({"p": "input", "t": "scroll", "dy": dy})
    evs.append({"p": "input", "t": "keydown", "k": "shift"})
    evs.append({"p": "input", "t": "keyup", "k": "shift"})
    return evs


def run(env: Env, seconds: int = 2) -> Result:
    from websockets.sync.client import connect

    r = Result(name="test_input")
    dev = env.pick_device()
    cfg = env.room(dev["device_id"])
    ws_base = env.server.replace("https://", "wss://").replace("http://", "ws://")
    url = f"{ws_base}/ws/signaling?token={cfg['token']}&device_id=qa-input"

    cur = None
    try:  # 记录本机鼠标位置，测试后恢复
        import pyautogui
        cur = pyautogui.position()
    except Exception:
        pass

    errors: List[dict] = []
    pongs: List[Any] = []
    events = _events()
    ping_at = None
    try:
        with connect(url, open_timeout=10, max_size=8 * 1024 * 1024) as ws:
            for ev in events:
                ws.send(json.dumps(ev))
                time.sleep(0.06)
            ws.send(json.dumps({"p": "ping", "ts": int(time.time() * 1000)}))
            ping_at = time.time()
            # Agent 逐个注入事件（pyautogui 调用有系统开销），留足 6s；再补一次 ping 兜底
            end = time.time() + max(6.0, seconds * 2)
            second_ping = False
            while time.time() < end:
                if not second_ping and time.time() - ping_at > 2.5:
                    ws.send(json.dumps({"p": "ping", "ts": int(time.time() * 1000)}))
                    second_ping = True
                try:
                    raw = ws.recv(timeout=max(0.1, min(1.0, end - time.time())))
                except TimeoutError:
                    continue
                if isinstance(raw, bytes):
                    continue
                m = json.loads(raw)
                if m.get("p") == "agent.error":
                    errors.append(m)
                elif m.get("p") == "pong":
                    pongs.append(m.get("ts"))
                    break
    finally:
        if cur is not None:
            try:
                import pyautogui
                pyautogui.moveTo(cur.x, cur.y)
            except Exception:
                pass

    log = log_tail(env.agent_log, 40)
    bad_log = [ln for ln in log.splitlines()
               if ("Traceback" in ln or "断链" in ln or "agent.error" in ln)]

    r.metrics.update({
        "events_sent": len(events),
        "agent_errors": len(errors),
        "pong": bool(pongs),
        "pong_ms": round((time.time() - ping_at) * 1000) if pongs and ping_at else None,
        "log_tail": log.splitlines()[-6:],
    })
    r.add("连发输入事件无 agent.error", not errors,
          f"{len(errors)} 个错误" + (f": {errors[:2]}" if errors else ""))
    r.add("突发后 Agent 仍响应 ping/pong", bool(pongs), f"pong={len(pongs)}")
    r.add("Agent 日志无异常", not bad_log, f"{len(bad_log)} 行可疑" if bad_log else "clean")
    still = [d for d in env.devices() if d["device_id"] == dev["device_id"] and d.get("online")]
    r.add("Agent 进程仍在线", bool(still), "device online")
    return r.finish()


if __name__ == "__main__":
    from .run_all import run_single
    raise SystemExit(run_single(run, "test_input"))