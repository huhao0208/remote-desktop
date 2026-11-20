"""剪贴板双向同步（协议 v2 §2）。

- 控制端 → 被控端：`{"p":"clip","dir":"up","text"}` → 写入本机剪贴板
- 被控端 → 控制端：`clip.sync.enable` 后每 800ms 轮询本机剪贴板，变了才推
  `{"p":"clip","dir":"down","text"}`

三条硬约束（否则会出现「你抄我、我抄你」的抖动）：
1. **md5 去重**：内容没变不发
2. **回环抑制**：自己刚写进去的内容，5 秒内不再推回控制端
3. **256 KB 上限**：大段二进制/代码会堵住 WS 文本帧，直接丢弃

平台取放：macOS `pbpaste/pbcopy`（有 pyobjc 时直接用 NSPasteboard，省掉每次
fork 一个进程）、Windows `Get-Clipboard/Set-Clipboard`、Linux `xclip`。
"""
from __future__ import annotations

import asyncio
import hashlib
import platform
import subprocess
import time
from typing import Any, Awaitable, Callable, Dict, Optional

SYSTEM = platform.system()
MAX_BYTES = 256 * 1024
SUPPRESS_SEC = 5.0
POLL_SEC = 0.8


# ---------------------------------------------------------------- 平台读写

def _mac_pasteboard() -> Optional[Any]:
    try:
        from AppKit import NSPasteboard, NSPasteboardTypeString

        return NSPasteboard, NSPasteboardTypeString
    except Exception:
        return None


_MAC_PB = _mac_pasteboard() if SYSTEM == "Darwin" else None


def read_text() -> Optional[str]:
    """读本机剪贴板文本；无内容/非文本返回 None。"""
    if _MAC_PB:
        pb = _MAC_PB[0].generalPasteboard()
        return pb.stringForType_(_MAC_PB[1])
    if SYSTEM == "Darwin":
        out = subprocess.run(["pbpaste"], capture_output=True, timeout=3)
        return out.stdout.decode("utf-8", "replace")
    if SYSTEM == "Windows":
        out = subprocess.run(["powershell", "-NoProfile", "-Command", "Get-Clipboard"],
                             capture_output=True, timeout=5)
        return out.stdout.decode("utf-8", "replace")
    out = subprocess.run(["xclip", "-o", "-selection", "clipboard"],
                         capture_output=True, timeout=3)
    return out.stdout.decode("utf-8", "replace")


def write_text(text: str) -> None:
    if _MAC_PB:
        pb = _MAC_PB[0].generalPasteboard()
        pb.clearContents()
        pb.setString_forType_(text, _MAC_PB[1])
        return
    if SYSTEM == "Darwin":
        p = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
        p.communicate(text.encode("utf-8"))
        return
    if SYSTEM == "Windows":
        subprocess.run(["powershell", "-NoProfile", "-Command", "Set-Clipboard -Value $input"],
                       input=text.encode("utf-16-le"), timeout=5, check=False)
        return
    p = subprocess.Popen(["xclip", "-i", "-selection", "clipboard"], stdin=subprocess.PIPE)
    p.communicate(text.encode("utf-8"))


def _digest(text: str) -> str:
    return hashlib.md5(text.encode("utf-8", "replace")).hexdigest()


# ---------------------------------------------------------------- 同步器

class ClipboardSync:
    """800ms 轮询 + md5 去重 + 5s 回环抑制。"""

    def __init__(
        self,
        send_json: Callable[[Dict[str, Any]], Awaitable[None]],
        log: Callable[[str], None] = print,
    ) -> None:
        self._send_json = send_json
        self._log = log
        self.enabled = False
        self._last_digest: Optional[str] = None
        self._suppress: Dict[str, float] = {}
        self._task: Optional[asyncio.Task] = None
        self._warned_big = False
        self.pushed = 0

    # ------------------------------------------------------------ 控制

    def start(self) -> None:
        if not self._task:
            self._task = asyncio.create_task(self._loop())

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            self._task = None
        self.enabled = False

    def set_enabled(self, enable: bool) -> None:
        self.enabled = bool(enable)
        if self.enabled:
            # 重新开启时把当前内容当基线，避免一开就推一次旧内容
            try:
                text = read_text() or ""
                self._last_digest = _digest(text) if text else None
            except Exception:
                self._last_digest = None
        self._log(f"[clip] 同步{'开启' if self.enabled else '关闭'}")

    # ------------------------------------------------------------ 上行（控制端 → 本机）

    def apply_up(self, text: str) -> bool:
        """写入本机剪贴板并标记抑制，避免 800ms 后又被推回控制端。"""
        if not text:
            return False
        if len(text.encode("utf-8", "replace")) > MAX_BYTES:
            self._log("[clip] 上行内容超过 256KB，丢弃")
            return False
        try:
            write_text(text)
        except Exception as e:
            self._log(f"[clip] 写剪贴板失败: {e}")
            return False
        d = _digest(text)
        self._suppress[d] = time.monotonic()
        self._last_digest = d
        return True

    # ------------------------------------------------------------ 下行轮询

    async def _loop(self) -> None:
        try:
            while True:
                await asyncio.sleep(POLL_SEC)
                if not self.enabled:
                    continue
                try:
                    text = await asyncio.to_thread(read_text)
                except Exception:
                    continue
                if not text:
                    continue
                d = _digest(text)
                if d == self._last_digest:
                    continue
                self._last_digest = d
                now = time.monotonic()
                # 清掉过期的抑制标记
                for k, ts in list(self._suppress.items()):
                    if now - ts > SUPPRESS_SEC:
                        self._suppress.pop(k, None)
                if d in self._suppress:
                    continue
                if len(text.encode("utf-8", "replace")) > MAX_BYTES:
                    if not self._warned_big:
                        self._log("[clip] 剪贴板内容超过 256KB，跳过")
                        self._warned_big = True
                    continue
                self._warned_big = False
                await self._send_json({"p": "clip", "dir": "down", "text": text})
                self.pushed += 1
        except asyncio.CancelledError:
            return