"""文件收发（协议 v3 §2 被控端侧）。

只做「帧 ↔ 磁盘」这一层：上层（agent.py）负责把 WS 文本帧解析成 dict 交进来，
再把返回的 dict 原样发回去。这里不碰网络、不碰 asyncio，全部同步调用——
一次 32KB 的写盘比一次事件循环调度还快，没必要为它开线程。

两条方向（协议 v3 §2 规则 1：方向由**发起方**决定，本模块只看 id）：

- `FileReceiver`：控制端 → 被控端，`file.offer/chunk/done/cancel` 进来
- `FileSender`：`file.get` 触发，本机文件 → 控制端，`file.chunk` 出去

安全边界全在 `safe_name` + `_within` 两处：文件传输是整个 agent 里唯一能把
**外部字符串变成磁盘路径**的入口，一旦漏一个 `..`，远控协议就等于任意文件写入。
所以名字过滤做在「入口」而不是「调用方记得做」。

只用 stdlib（`os/base64/hashlib/shutil/time`）：这块要在 Windows 上也能跑，
不能因为某台机器 pip 装坏了 pyautogui 就连文件都传不了。
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import os
import shutil
import time
from typing import Any, Callable, Dict, List, Optional

DEFAULT_MAX_BYTES = 4 << 30      # 4GiB，与协议 §2 规则 6 一致
CHUNK_BYTES = 32 * 1024          # 与协议 §1 一致：base64 后约 43.7KB
PROGRESS_BYTES = 1 << 20         # 规则 7：≥1MiB
PROGRESS_SEC = 0.5               # 规则 7：或 ≥500ms
LIST_MAX = 500                   # 规则 8 附带的条数限制
MAX_NAME = 200                   # 规则 5：文件名长度上限（字符数）

_ILLEGAL_CHARS = frozenset('<>:"|?*')

# Windows 保留设备名：以这些词为**主名**的文件在 Windows 上会打开/写入设备而不是
# 文件，`CON.txt` 也一样被当成 CON。跨平台统一改写（而不是「在 Windows 上才改」），
# 是因为同一个接收目录可能被 SMB/网盘同步到 Windows 机器上，落一个叫 CON 的文件
# 在那头会变成诡异的行为差异——统一规则比按平台分叉好排查。
_RESERVED_STEMS = frozenset(
    ["CON", "PRN", "AUX", "NUL"]
    + [f"COM{i}" for i in range(1, 10)]
    + [f"LPT{i}" for i in range(1, 10)]
)


# ------------------------------------------------------------------ 文件名

def _truncate_keep_ext(name: str, limit: int) -> str:
    """截到 limit 字符但保住扩展名——把 `.zip` 截掉会得到一个双击打不开的文件。

    **没超长时必须原样返回**：下面 `name[:keep] + ext` 在 `len(name) <= limit`
    时会把整个名字留下、再把扩展名追加一次，`a (1).zip` 会变成 `a (1).zip.zip`
    （改名冲突路径上必现，实测踩到）。
    """
    if len(name) <= limit:
        return name
    dot = name.rfind(".")
    ext = ""
    if 0 < dot < len(name) - 1 and len(name) - dot <= 12:
        ext = name[dot:]
    keep = max(limit - len(ext), 1)
    return name[:keep] + ext


def safe_name(raw: Any) -> str:
    """把控制端给的名字压成「一个目录内安全的 basename」。

    处理顺序 = 攻击面从大到小：

    1. 反斜杠统一成正斜杠后只取尾段——这是挡 `../../etc/passwd`、`C:\\x\\y`
       以及 `//server/share/file` 的唯一一步；**只取尾段**天然拒绝绝对路径和 `..`
    （`..` 取尾段就是 `..`，后面会被清成空）
    2. 控制字符（0x00-0x1F、0x7F）与 `< > : " | ? *` 换成下划线。**换而不是删**：
       删掉会把 `a<b` 和 `ab` 合并成同一个名字，前者静默覆盖后者；下划线保留了
       「这里有字符被改过」的痕迹
    3. 去掉结尾的点和空格：Windows 落盘时会**静默**丢掉它们，于是「回包给控制端
       的路径」和「真实文件名」不一致，用户点开就找不到
    4. 超过 200 字符截断（保扩展名）
    5. 空了就用 `unnamed`；保留设备名前面加下划线

    返回值永远非空、永远不含路径分隔符。
    """
    s = "" if raw is None else str(raw)
    s = s.replace("\\", "/")
    s = s.rsplit("/", 1)[-1]

    out: List[str] = []
    for ch in s:
        if ch in _ILLEGAL_CHARS or ord(ch) < 32 or ord(ch) == 127:
            out.append("_")
        else:
            out.append(ch)
    s = "".join(out)

    s = s.rstrip(". ")
    if len(s) > MAX_NAME:
        s = _truncate_keep_ext(s, MAX_NAME).rstrip(". ")

    if not s:
        return "unnamed"

    stem = s.split(".", 1)[0].strip().upper()
    if stem in _RESERVED_STEMS:
        s = "_" + s
    return s


def check_space(directory: str, size: int) -> bool:
    """目录剩余空间是否 ≥ 1.2×size（规则 6）。目录不存在 → False。

    用整数比较（`free*5 >= size*6`）而不是 `free >= 1.2*size`：4GiB 级别的浮点
    比较在边界上会差几百字节，而这种判断错一次就是「写一半没空间」。
    """
    try:
        free = shutil.disk_usage(directory).free
    except (OSError, ValueError):
        return False
    if size <= 0:
        return True
    return free * 5 >= size * 6


def _sha256_file(path: str) -> Optional[str]:
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                h.update(block)
    except OSError:
        return None
    return h.hexdigest()


def _unlink(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


class _Incoming:
    """一条上传任务的运行时状态。字段可变，故意不做 dataclass 的不可变花样——
    它就是一个被 chunk() 一直改的账本。"""

    __slots__ = ("id", "name", "path", "part", "expected", "written", "mode",
                 "fh", "failed", "err", "progress_n", "progress_at", "progress_ts")

    def __init__(self, tid: str, name: str, path: str, part: str,
                 expected: int, start: int, mode: str, fh) -> None:
        self.id = tid
        self.name = name
        self.path = path
        self.part = part
        self.expected = expected
        self.written = start
        self.mode = mode
        self.fh = fh
        self.failed = False
        self.err = ""
        # 首块立即发一次进度：UI 靠它从「排队中」翻到「接收中」，
        # 之后再按 1MiB / 500ms 节流（规则 7 关心的是别刷屏，不是首帧也省掉）
        self.progress_n = 0
        self.progress_at = start
        self.progress_ts = time.monotonic()


# ------------------------------------------------------------------ 接收

class FileReceiver:
    """控制端 → 被控端。

    落盘策略（为什么非得有 `.part`）：接收目录是用户会去翻的目录，一个传了一半
    的 `a.zip` 在那里看起来和好的没区别，双击就是「文件损坏」。所以**先写
    `<目标>.part`，sha256 校验通过后同目录 `os.replace` 一次性改名**——同目录
    rename 是原子的，目录里出现的 `a.zip` 必然是完整且校验过的。

    续传（`mode:"append"`）是唯一例外：目标文件本来就存在且大小正好等于 offset，
    这时直接 `r+b` 定位续写，**不复制前缀**——4GiB 的复制比续传本身还慢，
    而且这个文件在上一轮就已经以「半截」状态躺在目录里了，没有新增风险。
    """

    def __init__(self, receive_dir: str, max_bytes: int = DEFAULT_MAX_BYTES,
                 log: Callable[[str], None] = print) -> None:
        self.receive_dir = os.path.abspath(receive_dir)
        # realpath 一次并留作基准：后续所有目标路径都跟它比。注意接收目录本身
        # 可能是用户选的符号链接，这里**有意**跟随它（它就是用户想要的位置）。
        self._base = os.path.realpath(self.receive_dir)
        self.max_bytes = int(max_bytes)
        self._log = log
        self._tasks: Dict[str, _Incoming] = {}
        self._dead: set = set()
        self._ready = self._ensure_dir()

    # ------------------------------------------------------------ 内部

    def _ensure_dir(self) -> bool:
        try:
            os.makedirs(self.receive_dir, exist_ok=True)
            return os.path.isdir(self.receive_dir)
        except OSError as e:
            self._log(f"[file] 接收目录不可用 {self.receive_dir}: {e}")
            return False

    def _within(self, path: str) -> bool:
        """最终路径（realpath 后）必须仍在接收目录内。

        用 `commonpath` 而不是 `path.startswith(base)`：后者会让 `/tmp/ab`
        通过 `/tmp/a` 的检查；跨盘符时 commonpath 抛 ValueError，按越界处理。
        realpath 这一层是必要的——接收目录里可能躺着指向外部的符号链接
        （要么用户自己建的，要么上一轮传输留下的），不解析就会被写穿。
        """
        real = os.path.realpath(path)
        try:
            return os.path.commonpath([self._base, real]) == self._base
        except ValueError:
            return False

    def _unique(self, path: str) -> str:
        """`a.zip` → `a (1).zip` …（规则 4）。同时避开 `.part` 占位。"""
        base = os.path.basename(path)
        dot = base.rfind(".")
        has_ext = 0 < dot < len(base) - 1
        stem = base[:dot] if has_ext else base
        ext = base[dot:] if has_ext else ""
        for i in range(1, 1000):
            cand = _truncate_keep_ext(f"{stem} ({i}){ext}", MAX_NAME)
            full = os.path.join(self.receive_dir, cand)
            if not os.path.lexists(full) and not os.path.lexists(full + ".part"):
                return full
        return os.path.join(self.receive_dir,
                            _truncate_keep_ext(f"{stem} ({int(time.time() * 1000)}){ext}",
                                               MAX_NAME))

    @staticmethod
    def _close_handle(task: _Incoming) -> None:
        if task.fh is not None:
            try:
                task.fh.close()
            except OSError:
                pass
            task.fh = None

    def _fail(self, task: _Incoming, reason: str, msg: str) -> dict:
        task.failed = True
        task.err = reason
        self._close_handle(task)
        # 失败态不会被续写，`.part` 留着只是垃圾；append 的文件是用户已有的
        # 半截成果，保留（下一轮还能按 offset 续上）
        if task.mode != "append":
            _unlink(task.part)
        self._log(f"[file] {task.id} 失败 {reason}: {msg}")
        return {"p": "file.error", "id": task.id, "reason": reason, "msg": msg}

    def _maybe_progress(self, task: _Incoming) -> Optional[dict]:
        now = time.monotonic()
        if not (task.progress_n == 0
                or task.written - task.progress_at >= PROGRESS_BYTES
                or now - task.progress_ts >= PROGRESS_SEC):
            return None
        task.progress_n += 1
        task.progress_at = task.written
        task.progress_ts = now
        return {"p": "file.progress", "id": task.id, "received": task.written}

    # ------------------------------------------------------------ offer

    def offer(self, ev: dict) -> dict:
        tid = str(ev.get("id") or "")
        if not tid:
            return {"p": "file.reject", "id": "", "reason": "bad_name", "msg": "缺少 id"}
        if not self._ready:
            return {"p": "file.reject", "id": tid, "reason": "denied",
                    "msg": "接收目录不存在或不可写"}

        raw = ev.get("name")
        # 空名字不是「叫 unnamed 的文件」，而是控制端有 bug：拒绝比落一盘
        # unnamed 更容易被发现（真正只是被滤空的名字仍会落成 unnamed）
        if not isinstance(raw, str) or not raw.strip():
            return {"p": "file.reject", "id": tid, "reason": "bad_name", "msg": "文件名为空"}
        name = safe_name(raw)

        try:
            size = int(ev.get("size") or 0)
            offset = int(ev.get("offset") or 0)
        except (TypeError, ValueError):
            return {"p": "file.reject", "id": tid, "reason": "bad_name",
                    "msg": "size/offset 不是数字"}
        if size < 0 or offset < 0 or offset > size:
            return {"p": "file.reject", "id": tid, "reason": "bad_name",
                    "msg": "size/offset 越界"}
        if size > self.max_bytes:
            return {"p": "file.reject", "id": tid, "reason": "too_large",
                    "msg": f"超过单文件上限 {self.max_bytes} 字节"}
        if not check_space(self.receive_dir, size):
            return {"p": "file.reject", "id": tid, "reason": "no_space",
                    "msg": "接收目录剩余空间不足 1.2×size"}

        target = os.path.join(self.receive_dir, name)
        if not self._within(target):
            return {"p": "file.reject", "id": tid, "reason": "bad_name", "msg": "路径越界"}

        mode, start = "new", 0
        if os.path.lexists(target):
            same = os.path.isfile(target) and os.path.getsize(target) == offset
            if offset > 0 and same:
                mode, start = "append", offset
            else:
                target = self._unique(target)
                if not self._within(target):
                    return {"p": "file.reject", "id": tid, "reason": "bad_name",
                            "msg": "路径越界"}
                mode = "rename"

        part = target + ".part"
        try:
            if mode == "append":
                fh = open(target, "r+b")
                fh.seek(start)
                fh.truncate(start)   # 防御：外部曾把文件写长过
            else:
                fh = open(part, "wb")   # wb 会截断上一轮崩掉留下的同名 .part
        except OSError as e:
            return {"p": "file.reject", "id": tid, "reason": "denied",
                    "msg": f"无法创建目标文件: {e}"}

        task = _Incoming(tid, name, target, part, size, start, mode, fh)
        self._tasks[tid] = task
        self._log(f"[file] 接收 {tid} {os.path.basename(target)} {size}B mode={mode} start={start}")
        return {"p": "file.accept", "id": tid, "name": os.path.basename(target),
                "size": size, "path": target, "offset": start, "mode": mode}

    # ------------------------------------------------------------ chunk

    def chunk(self, ev: dict) -> Optional[dict]:
        tid = str(ev.get("id") or "")
        task = self._tasks.get(tid)
        if task is None:
            if tid in self._dead:
                return None   # 已知死任务：不再回包，否则重传风暴会刷出一条错误/块
            self._dead.add(tid)
            return {"p": "file.error", "id": tid, "reason": "io",
                    "msg": "任务不存在或已结束"}
        if task.failed:
            return None       # 已回过错误，静默丢弃后续块

        data = ev.get("data")
        if not isinstance(data, str) or not data:
            return self._fail(task, "io", "空的 data 字段")
        try:
            blob = base64.b64decode(data, validate=True)
        except (binascii.Error, ValueError) as e:
            return self._fail(task, "io", f"base64 解码失败: {e}")

        try:
            off = int(ev.get("off"))
        except (TypeError, ValueError):
            return self._fail(task, "offset", "off 不是数字")
        if off != task.written:
            # 规则 2：不做乱序重排，直接让发起方从 0 重传
            return self._fail(task, "offset", f"期望 off={task.written}，收到 {off}")
        if task.written + len(blob) > task.expected:
            return self._fail(task, "io", "写入字节数超过声明的 size")

        try:
            task.fh.write(blob)
        except OSError as e:
            return self._fail(task, "io", f"写盘失败: {e}")
        task.written += len(blob)
        return self._maybe_progress(task)

    # ------------------------------------------------------------ finish / cancel / close

    def finish(self, ev: dict) -> dict:
        tid = str(ev.get("id") or "")
        task = self._tasks.get(tid)
        if task is None:
            return {"p": "file.error", "id": tid, "reason": "io",
                    "msg": "任务不存在或已结束"}
        if task.failed:
            self._tasks.pop(tid, None)
            return {"p": "file.error", "id": tid, "reason": task.err or "io",
                    "msg": "任务已处于失败态"}

        if task.written != task.expected:
            out = self._fail(task, "io",
                             f"字节数不符：声明 {task.expected}，实收 {task.written}")
            self._tasks.pop(tid, None)
            return out

        self._close_handle(task)

        if task.mode == "append":
            # 续写是把新块接在旧文件尾部，收尾时把可能的外部超写截掉，
            # 保证落盘长度就是声明的 size
            try:
                with open(task.path, "r+b") as f:
                    f.truncate(task.expected)
            except OSError as e:
                out = self._fail(task, "io", f"截断失败: {e}")
                self._tasks.pop(tid, None)
                return out
            source = task.path
        else:
            source = task.part

        got = _sha256_file(source)
        if got is None:
            out = self._fail(task, "io", "读盘校验失败")
            self._tasks.pop(tid, None)
            return out

        want = ev.get("sha256")
        want = want.strip().lower() if isinstance(want, str) and want.strip() else ""
        if want and want != got:
            # 内容不对就删：留一个「长度对、内容错」的文件比没有更坑
            _unlink(source)
            _unlink(task.part)
            task.failed, task.err = True, "sha256"
            self._tasks.pop(tid, None)
            self._log(f"[file] {tid} sha256 不符，已删除 {source}")
            return {"p": "file.error", "id": tid, "reason": "sha256",
                    "msg": f"校验不符: 期望 {want[:12]}… 实得 {got[:12]}…"}

        if task.mode != "append":
            try:
                os.replace(task.part, task.path)   # 同目录原子改名
            except OSError as e:
                out = self._fail(task, "io", f"改名失败: {e}")
                self._tasks.pop(tid, None)
                return out

        self._tasks.pop(tid, None)
        self._log(f"[file] {tid} 完成 {task.path} {task.expected}B")
        return {"p": "file.complete", "id": tid, "path": task.path,
                "bytes": task.expected, "sha256": got}

    def cancel(self, ev: dict) -> None:
        tid = str(ev.get("id") or "")
        task = self._tasks.pop(tid, None)
        if task is None:
            return
        self._close_handle(task)
        if task.mode != "append":
            _unlink(task.part)
        self._dead.add(tid)
        self._log(f"[file] {tid} 已取消（{ev.get('reason') or 'user'}）")

    def close(self) -> None:
        """会话结束：句柄全关，未完成的 `.part` 全删——下次用户翻接收目录时
        不该看到上次连接留下的半截文件。"""
        for tid in list(self._tasks):
            task = self._tasks.pop(tid)
            self._close_handle(task)
            if task.mode != "append":
                _unlink(task.part)
        self._dead.clear()


# ------------------------------------------------------------------ 发送

class FileSender:
    """被控端 → 控制端（`file.get`）。

    与接收方向相反的安全问题：接收方向怕写到目录外，发送方向怕**读到**不该读的
    东西（比如整个磁盘）。所以必须有 `allowed_roots` 白名单，且用 realpath 后的
    commonpath 判断——`~/Documents/../.ssh/id_rsa` 这种拼法不能绕过去。
    白名单为空 = 全拒（fail closed），不是全开。
    """

    def __init__(self, allowed_roots: List[str], log: Callable[[str], None] = print) -> None:
        self._roots = [os.path.realpath(os.path.abspath(r)) for r in allowed_roots if r]
        self._log = log
        self._fh = None
        self._path = ""
        self._size = 0
        self._off = 0
        self._id = ""

    def _allowed(self, path: str) -> bool:
        for root in self._roots:
            try:
                if os.path.commonpath([root, path]) == root:
                    return True
            except ValueError:      # 跨盘符
                continue
        return False

    def open(self, ev: dict) -> dict:
        tid = str(ev.get("id") or "")
        raw = ev.get("path")
        if not isinstance(raw, str) or not raw.strip():
            return {"p": "file.error", "id": tid, "reason": "not_found", "msg": "缺少 path"}

        path = os.path.realpath(os.path.abspath(os.path.expanduser(raw)))
        if not self._allowed(path):
            return {"p": "file.error", "id": tid, "reason": "denied",
                    "msg": "路径不在允许共享的目录内"}
        if not os.path.exists(path):
            return {"p": "file.error", "id": tid, "reason": "not_found", "msg": "文件不存在"}
        if os.path.isdir(path):
            # 首版只传单文件：递归目录要处理软链、权限、深度，复杂度不值
            return {"p": "file.error", "id": tid, "reason": "denied",
                    "msg": "首版不支持发送目录"}

        try:
            size = os.path.getsize(path)
            offset = int(ev.get("offset") or 0)
        except (OSError, TypeError, ValueError) as e:
            return {"p": "file.error", "id": tid, "reason": "io", "msg": str(e)}
        offset = min(max(offset, 0), size)

        try:
            fh = open(path, "rb")
        except OSError as e:
            return {"p": "file.error", "id": tid, "reason": "io", "msg": str(e)}

        self.close()   # 一个 sender 同时只服务一条下载任务
        fh.seek(offset)
        self._fh, self._path, self._size, self._off, self._id = fh, path, size, offset, tid
        self._log(f"[file] 发送 {tid} {path} {size}B from {offset}")
        # 下载方向没有 mode 字段：续传与否由控制端的 offset 决定
        return {"p": "file.accept", "id": tid, "name": os.path.basename(path),
                "size": size, "path": path, "offset": offset}

    def next_chunk(self) -> Optional[dict]:
        """读下一块。读完返回 None（由调用方再发 complete）。"""
        if self._fh is None:
            return None
        try:
            blob = self._fh.read(CHUNK_BYTES)
        except OSError as e:
            tid = self._id
            self.close()
            return {"p": "file.error", "id": tid, "reason": "io", "msg": str(e)}
        if not blob:
            return None
        frame = {"p": "file.chunk", "id": self._id, "off": self._off,
                 "data": base64.b64encode(blob).decode("ascii")}
        self._off += len(blob)
        return frame

    def complete(self) -> dict:
        path, tid, size = self._path, self._id, self._size
        self.close()
        # 收尾重读一遍算 sha256：读流是顺序的，边读边算要额外维护「offset>0 时
        # 前缀怎么补」的状态，一次重读换来代码简单，代价只有一次磁盘顺序读
        digest = _sha256_file(path) or ""
        return {"p": "file.complete", "id": tid, "path": path,
                "bytes": size, "sha256": digest}

    def close(self) -> None:
        if self._fh is not None:
            try:
                self._fh.close()
            except OSError:
                pass
            self._fh = None


# ------------------------------------------------------------------ 列目录

def list_dir(receive_dir: str, subdir: str = "") -> dict:
    """`file.list.result`（规则 8）：只能列接收目录本身或它的子目录。

    不做「任意路径浏览」是产品决定也是安全决定：一旦允许浏览，agent 就成了一台
    没有认证的 SFTP 服务器，而它的鉴权只有「连上了这条 WS」。
    """
    base = os.path.realpath(os.path.abspath(receive_dir))
    sub = "" if subdir is None else str(subdir)
    if sub.startswith(("/", "\\")) or os.path.isabs(sub):
        return {"p": "file.error", "dir": sub, "reason": "denied",
                "msg": "只允许相对接收目录的路径"}

    target = os.path.realpath(os.path.join(base, sub))
    try:
        inside = os.path.commonpath([base, target]) == base
    except ValueError:
        inside = False
    if not inside:
        return {"p": "file.error", "dir": sub, "reason": "denied",
                "msg": "目录越界"}

    if not os.path.isdir(target):
        return {"p": "file.error", "dir": sub, "reason": "not_found", "msg": "目录不存在"}

    try:
        names = os.listdir(target)
    except OSError as e:
        return {"p": "file.error", "dir": sub, "reason": "io", "msg": str(e)}

    entries: List[dict] = []
    for name in names:
        full = os.path.join(target, name)
        try:
            st = os.stat(full)
        except OSError:
            continue    # 刚被删掉 / 无权限：跳过，不要因为一条坏项整页失败
        is_dir = os.path.isdir(full)
        entries.append({"name": name, "size": int(st.st_size),
                        "is_dir": is_dir, "mtime": int(st.st_mtime)})

    # 目录优先 + 名字不区分大小写：用户在面板里看到的就是「文件夹在上」，
    # 与任何文件管理器一致
    entries.sort(key=lambda e: (not e["is_dir"], e["name"].casefold()))
    return {"p": "file.list.result", "dir": sub, "entries": entries[:LIST_MAX]}
