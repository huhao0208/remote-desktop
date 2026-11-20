"""用例结果模型：统一 PASS / FAIL / SKIP 语义与输出格式。"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"


@dataclass
class Check:
    name: str
    ok: bool
    detail: str = ""
    # 阈值类检查保留实测值/阈值，便于报告直接引用
    value: Any = None
    limit: Any = None

    def as_dict(self) -> dict:
        d = {"name": self.name, "ok": self.ok, "detail": self.detail}
        if self.value is not None:
            d["value"] = self.value
        if self.limit is not None:
            d["limit"] = self.limit
        return d


@dataclass
class Result:
    name: str
    status: str = PASS
    checks: List[Check] = field(default_factory=list)
    metrics: Dict[str, Any] = field(default_factory=dict)
    skip_reason: Optional[str] = None
    error: Optional[str] = None
    duration_ms: int = 0
    started: float = field(default_factory=time.time)

    # -- 构造
    @classmethod
    def skip(cls, name: str, reason: str, metrics: Optional[dict] = None) -> "Result":
        return cls(name=name, status=SKIP, skip_reason=reason, metrics=metrics or {})

    def add(self, name: str, ok: bool, detail: str = "",
            value: Any = None, limit: Any = None) -> None:
        self.checks.append(Check(name, bool(ok), detail, value, limit))

    def finish(self) -> "Result":
        self.duration_ms = int((time.time() - self.started) * 1000)
        if self.status != SKIP:
            self.status = PASS if all(c.ok for c in self.checks) else FAIL
        return self

    # -- 输出
    def as_dict(self) -> dict:
        return {
            "name": self.name,
            "status": self.status,
            "duration_ms": self.duration_ms,
            "metrics": self.metrics,
            "checks": [c.as_dict() for c in self.checks],
            "skip_reason": self.skip_reason,
            "error": self.error,
        }

    def human(self) -> str:
        head = f"[{self.status}] {self.name}  ({self.duration_ms} ms)"
        lines = [head]
        if self.skip_reason:
            lines.append(f"        skip: {self.skip_reason}")
        if self.error:
            lines.append(f"        error: {self.error}")
        for c in self.checks:
            mark = "ok  " if c.ok else "FAIL"
            extra = f"  ({c.detail})" if c.detail else ""
            lines.append(f"        {mark} {c.name}{extra}")
        return "\n".join(lines)


def summarize(results: List[Result]) -> Dict[str, Any]:
    counts = {PASS: 0, FAIL: 0, SKIP: 0}
    for r in results:
        counts[r.status] = counts.get(r.status, 0) + 1
    return {
        "pass": counts[PASS],
        "fail": counts[FAIL],
        "skip": counts[SKIP],
        "total": len(results),
        "exit_code": 0 if counts[FAIL] == 0 else 1,
    }