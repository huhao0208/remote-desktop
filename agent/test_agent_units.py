"""被控端（agent 侧）单元测试：file_transfer + cursor。

`python agent/test_agent_units.py` 直接跑，纯 stdlib，不依赖 pytest。

**红线：绝不调用 cursor.set_visible / cursor.move_rel**。那会把正在用这台机器的
用户的鼠标藏起来（Windows 上还会留下一个不配对的 ShowCursor 计数）。这里只验证
`engine()` 的返回值和「模块能 import」——真正的光标行为只能靠人工验收。
"""
from __future__ import annotations

import base64
import hashlib
import os
import sys
import tempfile
import traceback
from typing import Any, Callable, List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cursor                     # noqa: E402
import file_transfer as ft        # noqa: E402

_CASES: List[Callable[[], None]] = []


def case(fn: Callable[[], None]) -> Callable[[], None]:
    _CASES.append(fn)
    return fn


def eq(got: Any, want: Any, what: str = "") -> None:
    if got != want:
        raise AssertionError(f"{what}: 期望 {want!r}，实际 {got!r}")


def ok(cond: bool, what: str) -> None:
    if not cond:
        raise AssertionError(what)


def payload(n: int, seed: int = 37) -> bytes:
    """确定性的伪随机字节：失败时能复现，不需要落 fixture 文件。"""
    return bytes((i * seed + 11) % 256 for i in range(n))


def sha(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


def b64(blob: bytes) -> str:
    return base64.b64encode(blob).decode("ascii")


# ------------------------------------------------------------------ safe_name

@case
def test_safe_name() -> None:
    # 穿越 / 绝对路径：只留尾段
    eq(ft.safe_name("../../etc/passwd"), "passwd", "相对穿越")
    eq(ft.safe_name("/absolute/photo.jpg"), "photo.jpg", "绝对路径")
    eq(ft.safe_name(r"C:\Users\x\a.zip"), "a.zip", "Windows 绝对路径")
    eq(ft.safe_name(r"..\..\boot.ini"), "boot.ini", "反斜杠穿越")
    eq(ft.safe_name("//server/share/f.txt"), "f.txt", "UNC")

    # 保留字符与控制字符 → 下划线（换而不是删：删了会让 a<b 覆盖 ab）
    eq(ft.safe_name('a<b>c:d|e?f*g.txt'), "a_b_c_d_e_f_g.txt", "保留字符")
    eq(ft.safe_name("a\x00b\x1fc\x7f.txt"), "a_b_c_.txt", "控制字符")

    # 结尾点/空格：Windows 会静默丢掉，导致回包路径 != 真实文件名
    eq(ft.safe_name("report."), "report", "结尾点")
    eq(ft.safe_name("report. . "), "report", "结尾点+空格")

    # Windows 保留设备名
    eq(ft.safe_name("CON"), "_CON", "CON")
    eq(ft.safe_name("con.txt"), "_con.txt", "con.txt")
    eq(ft.safe_name("LPT9.log"), "_LPT9.log", "LPT9")

    # 空/退化
    eq(ft.safe_name(""), "unnamed", "空串")
    eq(ft.safe_name("   "), "unnamed", "全空格")
    eq(ft.safe_name(".."), "unnamed", "..")
    eq(ft.safe_name("..."), "unnamed", "...")
    eq(ft.safe_name(None), "unnamed", "None")

    # 超长保扩展名
    long_name = "x" * 300 + ".tar.gz"
    got = ft.safe_name(long_name)
    ok(len(got) <= ft.MAX_NAME, f"超长名未截断: {len(got)}")
    ok(got.endswith(".gz"), f"扩展名丢了: {got[-8:]}")

    # 任何输入都不许带回路径分隔符
    for bad in ("a/b", "a\\b", "../x", "/etc/", "C:\\x\\y"):
        n = ft.safe_name(bad)
        ok("/" not in n and "\\" not in n, f"{bad!r} 仍带分隔符: {n!r}")


# ------------------------------------------------------------------ check_space

@case
def test_check_space() -> None:
    with tempfile.TemporaryDirectory() as td:
        ok(ft.check_space(td, 1), "正常目录应判定为有空间")
        ok(ft.check_space(td, 0), "0 字节应判定为有空间")
        ok(not ft.check_space(os.path.join(td, "nope"), 1), "不存在的目录必须 False")
        ok(not ft.check_space(td, 1 << 62), "4EiB 不可能放得下")


# ------------------------------------------------------------------ 接收：全流程

@case
def test_receive_full_flow() -> None:
    blob = payload(70_000)
    pieces = [blob[:1000], blob[1000:40000], blob[40000:]]
    with tempfile.TemporaryDirectory() as td:
        r = ft.FileReceiver(td)
        acc = r.offer({"p": "file.offer", "id": "f-1-0001", "name": "a.bin",
                       "size": len(blob), "offset": 0})
        eq(acc["p"], "file.accept", "accept")
        eq(acc["mode"], "new", "mode")
        eq(acc["offset"], 0, "accept offset")
        eq(acc["size"], len(blob), "accept size")
        target = acc["path"]
        eq(os.path.dirname(os.path.realpath(target)), os.path.realpath(td), "落盘目录")

        off = 0
        frames = []
        for piece in pieces:
            frames.append(r.chunk({"p": "file.chunk", "id": "f-1-0001",
                                   "off": off, "data": b64(piece)}))
            off += len(piece)

        # 首块立即回一次进度（UI 靠它翻成「接收中」），之后按 1MiB/500ms 节流
        eq(frames[0]["p"], "file.progress", "首块进度")
        eq(frames[0]["received"], 1000, "首块进度字节数")
        ok(frames[1] is None, "第二块应被节流吞掉")

        # 传输中：真实文件还不该出现，只有 .part
        ok(not os.path.exists(target), "未完成时不许出现目标文件")
        ok(os.path.exists(target + ".part"), "应当有一个 .part")

        done = r.finish({"p": "file.done", "id": "f-1-0001", "sha256": sha(blob)})
        eq(done["p"], "file.complete", "complete")
        eq(done["bytes"], len(blob), "complete bytes")
        eq(done["sha256"], sha(blob), "complete sha256")
        with open(target, "rb") as f:
            eq(f.read(), blob, "落盘字节一致")
        ok(not os.path.exists(target + ".part"), ".part 必须消失")
        r.close()


# ------------------------------------------------------------------ 同名冲突改名

@case
def test_receive_rename_conflict() -> None:
    with tempfile.TemporaryDirectory() as td:
        old = os.path.join(td, "a.zip")
        with open(old, "wb") as f:
            f.write(b"OLD")
        blob = b"NEW-CONTENT"
        r = ft.FileReceiver(td)
        acc = r.offer({"p": "file.offer", "id": "f-2-0001", "name": "a.zip",
                       "size": len(blob), "offset": 0})
        eq(acc["mode"], "rename", "冲突应走 rename")
        eq(os.path.basename(acc["path"]), "a (1).zip", "改名规则")
        eq(acc["name"], "a (1).zip", "accept 的 name 是真实名")
        r.chunk({"p": "file.chunk", "id": "f-2-0001", "off": 0, "data": b64(blob)})
        r.finish({"p": "file.done", "id": "f-2-0001", "sha256": sha(blob)})
        with open(old, "rb") as f:
            eq(f.read(), b"OLD", "原文件不许被覆盖")
        with open(acc["path"], "rb") as f:
            eq(f.read(), blob, "新文件内容")
        r.close()


# ------------------------------------------------------------------ 续传 append

@case
def test_receive_append_resume() -> None:
    blob = payload(5000, seed=7)
    with tempfile.TemporaryDirectory() as td:
        # 上一次会话留下 2000 字节的「半截目标文件」——续传的前提
        target = os.path.join(td, "big.bin")
        with open(target, "wb") as f:
            f.write(blob[:2000])

        r = ft.FileReceiver(td)
        acc = r.offer({"p": "file.offer", "id": "f-3-0001", "name": "big.bin",
                       "size": len(blob), "offset": 2000})
        eq(acc["mode"], "append", "size==offset 时走 append")
        eq(acc["offset"], 2000, "append 从 offset 续写")
        eq(acc["path"], target, "append 不换名字")

        r.chunk({"p": "file.chunk", "id": "f-3-0001", "off": 2000,
                 "data": b64(blob[2000:])})
        done = r.finish({"p": "file.done", "id": "f-3-0001", "sha256": sha(blob)})
        eq(done["p"], "file.complete", "append complete")
        with open(target, "rb") as f:
            eq(f.read(), blob, "续传后内容完整")

        # 大小对不上：不能续写，改名重来并从 0 开始
        with open(os.path.join(td, "m.bin"), "wb") as f:
            f.write(b"12345")
        acc2 = r.offer({"p": "file.offer", "id": "f-3-0002", "name": "m.bin",
                        "size": 100, "offset": 50})
        eq(acc2["mode"], "rename", "offset 与现有大小不符 → rename")
        eq(acc2["offset"], 0, "rename 后从 0 开始")
        eq(os.path.basename(acc2["path"]), "m (1).bin", "改名")
        r.close()


# ------------------------------------------------------------------ 错误路径

@case
def test_receive_offset_gap() -> None:
    with tempfile.TemporaryDirectory() as td:
        r = ft.FileReceiver(td)
        r.offer({"p": "file.offer", "id": "f-4-0001", "name": "x.bin",
                 "size": 100, "offset": 0})
        err = r.chunk({"p": "file.chunk", "id": "f-4-0001", "off": 10, "data": b64(b"x")})
        eq(err["p"], "file.error", "跳块应报错")
        eq(err["reason"], "offset", "reason=offset")
        # 失败态之后：静默丢弃，不再刷错误帧
        ok(r.chunk({"p": "file.chunk", "id": "f-4-0001", "off": 0,
                    "data": b64(b"x")}) is None, "失败态应静默")
        fin = r.finish({"p": "file.done", "id": "f-4-0001"})
        eq(fin["reason"], "offset", "finish 复述失败原因")
        eq(os.listdir(td), [], "失败不许留半截文件")
        r.close()


@case
def test_receive_bad_base64() -> None:
    with tempfile.TemporaryDirectory() as td:
        r = ft.FileReceiver(td)
        r.offer({"p": "file.offer", "id": "f-4-0002", "name": "y.bin",
                 "size": 10, "offset": 0})
        err = r.chunk({"p": "file.chunk", "id": "f-4-0002", "off": 0, "data": "!!!notb64!!!"})
        eq(err["reason"], "io", "坏 base64 → io")
        eq(os.listdir(td), [], "坏块不许留文件")
        r.close()


@case
def test_receive_sha256_mismatch() -> None:
    blob = payload(4096)
    with tempfile.TemporaryDirectory() as td:
        r = ft.FileReceiver(td)
        acc = r.offer({"p": "file.offer", "id": "f-5-0001", "name": "s.bin",
                       "size": len(blob), "offset": 0})
        r.chunk({"p": "file.chunk", "id": "f-5-0001", "off": 0, "data": b64(blob)})
        err = r.finish({"p": "file.done", "id": "f-5-0001", "sha256": "0" * 64})
        eq(err["p"], "file.error", "sha 不符应报错")
        eq(err["reason"], "sha256", "reason=sha256")
        ok(not os.path.exists(acc["path"]), "校验失败的目标文件必须删掉")
        eq(os.listdir(td), [], "目录里什么都不该剩")
        r.close()


@case
def test_receive_rejects() -> None:
    with tempfile.TemporaryDirectory() as td:
        small = ft.FileReceiver(td, max_bytes=100)
        rej = small.offer({"p": "file.offer", "id": "f-6-0001", "name": "big.bin",
                           "size": 101, "offset": 0})
        eq(rej["p"], "file.reject", "超限应 reject")
        eq(rej["reason"], "too_large", "reason=too_large")

        for bad in ("", "   ", None, 123):
            rj = small.offer({"p": "file.offer", "id": "f-6-0002", "name": bad,
                              "size": 1, "offset": 0})
            eq(rj["reason"], "bad_name", f"非法名字 {bad!r}")

        rj = small.offer({"p": "file.offer", "id": "f-6-0003", "name": "a.bin",
                          "size": -5, "offset": 0})
        eq(rj["reason"], "bad_name", "负 size")

        # 磁盘不足：临时把 check_space 打桩（真去塞满盘不现实）
        saved = ft.check_space
        ft.check_space = lambda d, s: False
        try:
            rj = small.offer({"p": "file.offer", "id": "f-6-0004", "name": "a.bin",
                              "size": 10, "offset": 0})
            eq(rj["reason"], "no_space", "reason=no_space")
            eq(os.listdir(td), [], "no_space 不许留文件")
        finally:
            ft.check_space = saved
        small.close()


@case
def test_receiver_path_guard() -> None:
    """realpath + commonpath 的双重防线（含 `/tmp/a` 不能匹配 `/tmp/ab`）。"""
    with tempfile.TemporaryDirectory() as td, \
            tempfile.TemporaryDirectory() as outside:
        base = os.path.join(td, "recv")
        os.makedirs(base)
        r = ft.FileReceiver(base)

        # 正常子路径
        ok(r._within(os.path.join(base, "a.txt")), "目录内文件应放行")

        # 前缀混淆：/tmp/x/recv 与 /tmp/x/recv2 不是父子关系
        sibling = base + "2"
        os.makedirs(sibling, exist_ok=True)
        ok(not r._within(os.path.join(sibling, "a.txt")), "前缀相近的兄弟目录必须拒绝")

        # 符号链接指向外部：realpath 之后必然越界
        link = os.path.join(base, "evil")
        try:
            os.symlink(outside, link)
        except (OSError, NotImplementedError):
            return          # 无符号链接权限的平台上跳过这一半
        ok(not r._within(os.path.join(link, "pwn.txt")), "软链穿出接收目录必须拒绝")
        r.close()


# ------------------------------------------------------------------ 生命周期

@case
def test_receiver_close_cleans_part() -> None:
    with tempfile.TemporaryDirectory() as td:
        r = ft.FileReceiver(td)
        acc = r.offer({"p": "file.offer", "id": "f-7-0001", "name": "c.bin",
                       "size": 100, "offset": 0})
        r.chunk({"p": "file.chunk", "id": "f-7-0001", "off": 0, "data": b64(b"x" * 10)})
        ok(os.path.exists(acc["path"] + ".part"), "写入期间应有 .part")
        r.close()
        eq(os.listdir(td), [], "close 必须清掉未完成的 .part")

        # cancel 同样要清
        r2 = ft.FileReceiver(td)
        acc2 = r2.offer({"p": "file.offer", "id": "f-7-0002", "name": "d.bin",
                         "size": 100, "offset": 0})
        r2.chunk({"p": "file.chunk", "id": "f-7-0002", "off": 0, "data": b64(b"y" * 10)})
        r2.cancel({"p": "file.cancel", "id": "f-7-0002", "reason": "user"})
        ok(not os.path.exists(acc2["path"] + ".part"), "cancel 必须清掉 .part")
        eq(os.listdir(td), [], "cancel 后目录应为空")
        # 已取消任务的残块：静默丢弃
        ok(r2.chunk({"p": "file.chunk", "id": "f-7-0002", "off": 10,
                     "data": b64(b"z")}) is None, "cancel 后的块应静默")
        r2.close()


# ------------------------------------------------------------------ 发送

@case
def test_sender_chunks_file() -> None:
    blob = payload(100 * 1024, seed=13)
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "dl.bin")
        with open(path, "wb") as f:
            f.write(blob)

        s = ft.FileSender([td])
        acc = s.open({"p": "file.get", "id": "f-8-0001", "path": path, "offset": 0})
        eq(acc["p"], "file.accept", "sender accept")
        eq(acc["size"], len(blob), "accept size")
        eq(acc["offset"], 0, "accept offset")

        # 把块大小压到 60KB，100KB 正好切成 2 块（避免造 100MB 的测试文件）
        saved = ft.CHUNK_BYTES
        ft.CHUNK_BYTES = 60 * 1024
        try:
            got = []
            while True:
                fr = s.next_chunk()
                if fr is None:
                    break
                eq(fr["p"], "file.chunk", "chunk 帧")
                eq(fr["off"], sum(len(g) for g in got), "chunk 的 off 必须连续")
                got.append(base64.b64decode(fr["data"]))
        finally:
            ft.CHUNK_BYTES = saved
        eq(len(got), 2, "100KB / 60KB 应切成 2 块")
        eq(b"".join(got), blob, "拼回来的字节一致")

        done = s.complete()
        eq(done["p"], "file.complete", "sender complete")
        eq(done["bytes"], len(blob), "complete bytes")
        eq(done["sha256"], sha(blob), "complete sha256")

        # 带 offset 的下载（续传方向）
        acc2 = s.open({"p": "file.get", "id": "f-8-0002", "path": path, "offset": 1000})
        eq(acc2["offset"], 1000, "续传起点")
        fr = s.next_chunk()
        eq(fr["off"], 1000, "首块 off = offset")
        s.close()


@case
def test_sender_denies() -> None:
    with tempfile.TemporaryDirectory() as td, \
            tempfile.TemporaryDirectory() as outside:
        inside = os.path.join(td, "ok.txt")
        with open(inside, "wb") as f:
            f.write(b"hi")
        secret = os.path.join(outside, "secret.txt")
        with open(secret, "wb") as f:
            f.write(b"nope")

        s = ft.FileSender([td])
        eq(s.open({"p": "file.get", "id": "g1", "path": secret})["reason"],
           "denied", "白名单外 → denied")
        eq(s.open({"p": "file.get", "id": "g2", "path": td})["reason"],
           "denied", "目录 → denied")
        eq(s.open({"p": "file.get", "id": "g3",
                   "path": os.path.join(td, "missing.txt")})["reason"],
           "not_found", "不存在 → not_found")
        # 用 .. 拼出去
        eq(s.open({"p": "file.get", "id": "g4",
                   "path": os.path.join(td, "..", os.path.basename(outside), "secret.txt")})["reason"],
           "denied", ".. 穿越 → denied")

        eq(ft.FileSender([]).open({"p": "file.get", "id": "g5", "path": inside})["reason"],
           "denied", "白名单为空 = 全拒（fail closed）")
        s.close()


# ------------------------------------------------------------------ 列目录

@case
def test_list_dir() -> None:
    with tempfile.TemporaryDirectory() as td, \
            tempfile.TemporaryDirectory() as outside:
        base = os.path.join(td, "recv")
        os.makedirs(os.path.join(base, "sub"))
        for name, body in (("a.txt", b"12345"), ("B.txt", b"1")):
            with open(os.path.join(base, name), "wb") as f:
                f.write(body)
        with open(os.path.join(outside, "secret.txt"), "wb") as f:
            f.write(b"x")

        res = ft.list_dir(base)
        eq(res["p"], "file.list.result", "list 帧")
        names = [e["name"] for e in res["entries"]]
        eq(names, ["sub", "a.txt", "B.txt"], "目录优先 + 名字排序")
        by = {e["name"]: e for e in res["entries"]}
        ok(by["sub"]["is_dir"] is True, "sub 是目录")
        eq(by["a.txt"]["size"], 5, "文件大小")
        ok(isinstance(by["a.txt"]["mtime"], int), "mtime 是整数")

        eq(ft.list_dir(base, "sub")["entries"], [], "空子目录")
        eq(ft.list_dir(base, "nope")["reason"], "not_found", "不存在")
        eq(ft.list_dir(base, "..")["reason"], "denied", ".. 越界")
        eq(ft.list_dir(base, outside)["reason"], "denied", "绝对路径越界")
        eq(ft.list_dir(base, "../" + os.path.basename(outside))["reason"], "denied",
           "相对穿越越界")

        link = os.path.join(base, "out")
        try:
            os.symlink(outside, link)
        except (OSError, NotImplementedError):
            return
        eq(ft.list_dir(base, "out")["reason"], "denied", "软链穿出接收目录")

    # 500 条上限
    with tempfile.TemporaryDirectory() as td2:
        base2 = os.path.join(td2, "recv")
        os.makedirs(base2)
        for i in range(505):
            with open(os.path.join(base2, f"f{i:03d}.txt"), "wb"):
                pass
        res2 = ft.list_dir(base2)
        eq(len(res2["entries"]), ft.LIST_MAX, "entries 上限")
        eq(res2["entries"][0]["name"], "f000.txt", "截断后顺序仍从头上开始")


# ------------------------------------------------------------------ cursor

@case
def test_cursor_engine_only() -> None:
    """只测 engine() 与可 import——**不碰** set_visible / move_rel。

    调一次 set_visible 就会改这台机器的真实光标；Windows 上还会留下不配对的
    ShowCursor 计数，测试进程退出后光标状态可能一直是隐藏的。
    """
    eng = cursor.engine()
    ok(eng in ("win-show-cursor", "mac-cgdisplay", "unsupported"),
       f"engine() 返回值非法: {eng!r}")
    for fn in ("set_visible", "move_rel", "restore", "engine"):
        ok(callable(getattr(cursor, fn, None)), f"缺少 {fn}()")
    # 纯函数路径：非数字/零位移必须静默返回，不许抛异常（也不会真的动）
    cursor.move_rel("x", None)
    cursor.move_rel(0, 0)


# ------------------------------------------------------------------ 控制端麦克风放音（协议 v3 §6）

@case
def test_audio_backend_optional() -> None:
    """没有音频后端时必须安静降级，不能 import 失败。"""
    import audio_playback as ap
    # 后端未知也不许抛：available() 是一个纯查询
    ok(isinstance(ap.available(), bool), "available() 应返回 bool")
    ok(isinstance(ap.backend(), str), "backend() 应返回字符串")
    ok(ap.FRAME_BYTES == 1920, "20ms@48kHz 单声道 s16 应为 1920 字节")


@case
def test_speaker_without_backend_is_noop() -> None:
    """没后端时 start() 返回 False，write/close 不崩——这条保证画面不受影响。"""
    import audio_playback as ap
    spk = ap.Speaker()
    if ap.available():
        # 有后端也不该在这儿真的开扬声器（会把测试机弄响），直接跳过
        spk.close()
        return
    ok(spk.start() is False, "无后端时 start() 应返回 False")
    spk.write(b"\x01" * 4096)      # 未打开 → 静默丢弃
    eq(spk.written, 0, "未打开的扬声器不应记录写入")
    spk.close()
    spk.close()                     # 幂等


@case
def test_speaker_backpressure_drops_oldest() -> None:
    """缓冲超限时必须丢最早的块：喊话场景延迟比完整性重要。"""
    import audio_playback as ap
    spk = ap.Speaker()
    # 手工置位绕过 start()，避免真的打开音频设备
    spk._opened = True
    try:
        total = ap.MAX_BUFFER_BYTES * 3
        chunk = b"\x11" * ap.FRAME_BYTES
        sent = 0
        while sent < total:
            spk.write(chunk)
            sent += len(chunk)
        ok(spk.dropped > 0, "超过缓冲上限必须丢数据")
        ok(spk._buf_bytes <= ap.MAX_BUFFER_BYTES, "缓冲必须被压回上限以内")
        # 丢的是旧的：最后写入的那块一定还在队尾
        ok(spk._buf[-1] == chunk, "最后写入的块必须保留（丢旧不丢新）")
    finally:
        spk._opened = False
        spk.close()


@case
def test_speaker_underrun_pads_silence() -> None:
    """缓冲不足时补静音而不是返回短数据——否则 PortAudio 会爆音。"""
    import audio_playback as ap
    spk = ap.Speaker()
    spk._opened = True
    try:
        # 一个字都没写就取 → 全是静音
        got = spk._take(ap.FRAME_BYTES)
        eq(len(got), ap.FRAME_BYTES, "不足时也必须给满帧")
        ok(got == b"\x00" * ap.FRAME_BYTES, "补的必须是静音")
        eq(spk.underruns, 1, "不足应记一次 underrun")

        spk.write(b"\x22" * 100)
        got = spk._take(ap.FRAME_BYTES)
        eq(len(got), ap.FRAME_BYTES, "部分数据也要补满")
        ok(got[:100] == b"\x22" * 100, "先吐已有的真实数据")
        ok(got[100:] == b"\x00" * (ap.FRAME_BYTES - 100), "再补静音")
    finally:
        spk._opened = False
        spk.close()


@case
def test_to_s16_mono_survives_garbage() -> None:
    """转换器遇到不认识的帧必须返回 None，不能抛（实时路径不容异常）。"""
    import audio_playback as ap
    eq(ap._to_s16_mono(object()), None, "垃圾输入应返回 None")


# ------------------------------------------------------------------ 入口

def main() -> int:
    passed = failed = 0
    for fn in _CASES:
        try:
            fn()
        except Exception:                       # noqa: BLE001
            failed += 1
            print(f"FAIL {fn.__name__}")
            traceback.print_exc()
        else:
            passed += 1
            print(f"ok   {fn.__name__}")
    print(f"PASS {passed} / FAIL {failed}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
