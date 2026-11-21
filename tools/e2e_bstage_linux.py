#!/usr/bin/env python3
"""B 阶段 Linux 被控端协议级清单验证（docs/nas-vm-debug.md §5 可自动化部分）。

前置：srv2 已运行，Linux Agent（JPEG 通路）已接入同一手机号。
运行：python tools/e2e_bstage_linux.py --server http://192.168.31.152:18443 \
        --mobile 13800000001 [--size-mb 100] [--save-frame PATH] [--skip-upload]

覆盖项（对应清单编号）：
  #1 JPEG 帧流：FRM1 可解码、尺寸与 hello.screen 一致
  #3/#4 hello 契约：os=Linux、cursor=unsupported（鼠标/外设面板置灰依据）、file=true
  #5 文件上传：sha256 一致 + accept.mode=new + complete.path 落盘（.part 残留需 NAS 侧确认）
  #6 同名冲突：第二次上传同名文件 → accept.mode=rename "… (1).ext"
  #7 下载白名单：/etc/hosts 成功且 sha256 一致；/etc/shadow → file.error reason=denied
  #8/#9 mic 降级：连发 5 次 mic enable → 每次都有 mic.state 回执（JPEG 通路 ok=false
      err=unsupported、on=false），无卡死。真实音频轨需 WebRTC+声卡，此环境验不了。
  #10 组合键降级：ctrl+alt+delete 原子组合发出后连接保持、无 agent.error
  #11 断链重连（控制端侧）：断开 WS 重进房间 → 收到 agent 因 peer.join 重发的 hello。
      Agent 进程级重连（kill → 5s 自动回原房间）由外部 pkill + device/list 观察。

不覆盖（需人工或其他手段）：#2 跟手感（本脚本只发一次 move，位置由 NAS 侧核对）、
#3/#4 面板 UI 置灰渲染、#8 真实出声、WebRTC 通路。
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import io
import json
import os
import sys
import time

import httpx
import websockets
from PIL import Image

FRAME_MAGIC = b"FRM1"
CHUNK = 32 * 1024  # 协议 v3 §2：file.chunk 原始数据 ≤32KB，base64 后走信令
MOVE_TO = (0.75, 0.25)  # 非中心坐标，便于 NAS 侧核对 Xvfb 指针位置（1920*0.75, 1080*0.25）


class Collector:
    """后台收 WS 消息：JPEG 帧只计数，文本按 p 分类进桶。"""

    def __init__(self, ws):
        self.ws = ws
        self.hello = None
        self.frames = 0
        self.last_frame = None
        self.errors = []
        self.mic_states = []
        self.file_msgs = []
        self.peers = []
        self.pongs = 0

    def start(self):
        asyncio.get_running_loop().create_task(self._run())

    async def _run(self):
        while True:
            try:
                raw = await self.ws.recv()
            except websockets.ConnectionClosed:
                return
            if isinstance(raw, bytes):
                if raw.startswith(FRAME_MAGIC):
                    body = raw[4:]
                    if body[:2] != b"\xff\xd8" and len(body) > 10:
                        body = body[8:]
                    self.frames += 1
                    self.last_frame = body
                continue
            m = json.loads(raw)
            p = m.get("p")
            if p == "agent.hello":
                self.hello = m
            elif p == "agent.error":
                self.errors.append(m)
            elif p == "mic.state":
                self.mic_states.append(m)
            elif p and p.startswith("file."):
                self.file_msgs.append(m)
            elif p == "peer.join":
                self.peers.append(m)
            elif p == "pong":
                self.pongs += 1

    async def wait_msg(self, bucket, pred, timeout=10.0):
        """在某个桶里按到达顺序等第一条满足 pred 的消息，超时返回 None。"""
        deadline = asyncio.get_running_loop().time() + timeout
        idx = 0
        while True:
            while idx < len(bucket):
                m = bucket[idx]
                idx += 1
                if pred(m):
                    return m
            if asyncio.get_running_loop().time() > deadline:
                return None
            await asyncio.sleep(0.05)

    async def wait_hello(self, timeout=8.0):
        deadline = asyncio.get_running_loop().time() + timeout
        while self.hello is None and asyncio.get_running_loop().time() < deadline:
            await asyncio.sleep(0.05)
        return self.hello


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


async def upload(ws, col: Collector, data: bytes, name: str):
    """上传一个文件，返回 (accept, complete)；失败返回 (accept_or_reject, None)。"""
    fid = "f-%d" % int(time.time() * 1000)
    await ws.send(json.dumps({"p": "file.offer", "id": fid, "name": name,
                              "size": len(data), "offset": 0}))
    acc = await col.wait_msg(
        col.file_msgs,
        lambda m: m.get("id") == fid and m.get("p") in ("file.accept", "file.reject"),
        timeout=15)
    if not acc or acc.get("p") == "file.reject":
        return acc, None
    digest = sha256_hex(data)
    for off in range(0, len(data), CHUNK):
        await ws.send(json.dumps({"p": "file.chunk", "id": fid, "off": off,
                                  "data": base64.b64encode(data[off:off + CHUNK]).decode()}))
    await ws.send(json.dumps({"p": "file.done", "id": fid, "sha256": digest}))
    # 上传吞吐约 2MB/s（base64 走信令 WS），超时按体量放宽
    comp = await col.wait_msg(col.file_msgs, lambda m: m.get("id") == fid and m.get("p") == "file.complete",
                              timeout=max(30, len(data) / (1 << 20) * 3))
    return acc, comp


async def download(ws, col: Collector, path: str):
    """发起下载，返回 (complete_or_error, 收到的字节)。"""
    fid = "d-%d" % int(time.time() * 1000)
    await ws.send(json.dumps({"p": "file.get", "id": fid, "path": path, "offset": 0}))
    fin = await col.wait_msg(
        col.file_msgs,
        lambda m: m.get("id") == fid and m.get("p") in ("file.complete", "file.error"),
        timeout=20)
    buf = bytearray()
    for m in col.file_msgs:
        if m.get("id") == fid and m.get("p") == "file.chunk":
            buf += base64.b64decode(m["data"])
    return fin, bytes(buf)


async def main(args) -> int:
    results = []

    def check(name, ok, detail=""):
        results.append(ok)
        print(("PASS " if ok else "FAIL ") + name + (("  | " + detail) if detail else ""))

    async with httpx.AsyncClient(base_url=args.server, timeout=15) as hc:
        login = (await hc.post("/api/v1/login/by_mobile", json={"mobile": args.mobile})).json()
        assert login["code"] == 0, login
        h = {"Authorization": "Bearer " + login["data"]["token"]}
        dl = (await hc.post("/api/v1/device/list", headers=h)).json()["data"]["list"]
        online = [d for d in dl if d["online"] and d.get("controllable", d.get("platform") == "pc")]
        assert online, f"no online device: {dl}"
        dev = online[0]
        print("device:", dev["device_name"], dev["device_id"])
        room = (await hc.post("/api/v1/room/join/by_device/" + dev["device_id"], headers=h)).json()
        assert room["code"] == 0, room
        cfg = room["data"]

    ws_base = args.server.replace("https://", "wss://").replace("http://", "ws://")
    url = ws_base + f"/ws/signaling?token={cfg['token']}&device_id=checklist-phone"

    async with websockets.connect(url, max_size=8 * 1024 * 1024) as ws:
        col = Collector(ws)
        col.start()

        hello = await col.wait_hello()
        check("#1 hello 收到", bool(hello), f"name={hello and hello.get('name')} os={hello and hello.get('os')}")
        # #3/#4：面板置灰的协议契约点
        check("#4 hello.os=Linux（外设面板同平台置灰依据）",
              hello and hello.get("os") == "Linux", str(hello and hello.get("os")))
        check("#3 hello.cursor=unsupported（鼠标面板置灰依据）",
              hello and hello.get("cursor") == "unsupported", str(hello and hello.get("cursor")))
        check("hello.file=true + receive_dir 上报",
              bool(hello and hello.get("file")) and bool(hello and hello.get("receive_dir")),
              str(hello and hello.get("receive_dir")))

        # #1：JPEG 帧流
        await asyncio.sleep(3.0)
        ok = col.frames > 0 and col.last_frame
        size_ok = False
        img_info = ""
        if ok:
            try:
                img = Image.open(io.BytesIO(col.last_frame))
                img.load()
                scr = hello.get("screen", {})
                size_ok = (img.width, img.height) == (scr.get("w"), scr.get("h"))
                img_info = f"{img.format} {img.size} {len(col.last_frame) // 1024}KB, {col.frames} 帧/3s"
                if args.save_frame:
                    with open(args.save_frame, "wb") as f:
                        f.write(col.last_frame)
                    img_info += f" → 已存 {args.save_frame}"
            except Exception as e:
                img_info = f"解码失败: {e}"
        check("#1 JPEG 帧流可解码且尺寸=hello.screen", bool(ok and size_ok), img_info)

        # #8/#9：mic 连续开关 5 次（JPEG 通路预期 unsupported 降级回执）
        mic_ok, mic_detail = True, []
        for i in range(5):
            await ws.send(json.dumps({"p": "mic", "enable": i % 2 == 0}))
            st = await col.wait_msg(col.mic_states, lambda m: True, timeout=5)
            if not st:
                mic_ok = False
                mic_detail.append(f"第{i + 1}次无回执")
                break
            mic_detail.append(f"{i + 1}:ok={st.get('ok')},on={st.get('on')},err={st.get('err')}")
        check("#8/#9 mic 5 次开关均有 mic.state 回执（降级 on=false）",
              mic_ok and all(s.get("on") is False for s in col.mic_states[:5]),
              "; ".join(mic_detail))

        # #10：Ctrl+Alt+Del 原子组合，连接应保持、无 error
        n_err = len(col.errors)
        await ws.send(json.dumps({"p": "input", "t": "key", "combo": ["ctrl", "alt", "delete"]}))
        await asyncio.sleep(1.5)
        await ws.send(json.dumps({"p": "ping", "ts": 1}))
        pong_ok = False
        try:
            deadline = asyncio.get_running_loop().time() + 3
            while col.pongs == 0 and asyncio.get_running_loop().time() < deadline:
                await asyncio.sleep(0.05)
            pong_ok = col.pongs > 0
        finally:
            pass
        check("#10 ctrl+alt+delete 无 error 且连接保持",
              pong_ok and len(col.errors) == n_err,
              f"agent.error 新增={len(col.errors) - n_err}")

        # #2：指针位置核对（只发一次 move，NAS 侧 pyautogui.position 核对）
        await ws.send(json.dumps({"p": "input", "t": "move", "x": MOVE_TO[0], "y": MOVE_TO[1]}))
        await asyncio.sleep(0.8)
        print(f"#2 已发 move → ({MOVE_TO[0]}, {MOVE_TO[1]})，请在 NAS 侧核对指针 "
              f"== ({int(1920 * MOVE_TO[0])}, {int(1080 * MOVE_TO[1])})")

        # #5/#6：上传 + 同名冲突
        if not args.skip_upload:
            size = args.size_mb * (1 << 20)
            print(f"#5 生成 {args.size_mb}MB 随机数据上传中（约 {args.size_mb // 2}s+）…")
            data = os.urandom(size)
            name = "nas-vm-checklist.bin"
            acc, comp = await upload(ws, col, data, name)
            check("#5 上传 accept.mode=new",
                  bool(acc) and acc.get("p") == "file.accept" and acc.get("mode") == "new",
                  f"mode={acc and acc.get('mode')}")
            check("#5 complete sha256 一致",
                  bool(comp) and comp.get("sha256") == sha256_hex(data),
                  f"expect={sha256_hex(data)[:16]}… got={comp and (comp.get('sha256') or '')[:16]}…")
            check("#5 complete.path 在接收目录（.part 已改名）",
                  bool(comp) and comp.get("path", "").endswith(name) and ".part" not in comp.get("path", ""),
                  str(comp and comp.get("path")))

            acc2, comp2 = await upload(ws, col, data, name)
            check("#6 同名第二次 → mode=rename 落成 '… (1).bin'",
                  bool(acc2) and acc2.get("mode") == "rename"
                  and " (1)." in (acc2.get("path") or ""),
                  f"mode={acc2 and acc2.get('mode')} path={acc2 and acc2.get('path')}")

            # #7：下载白名单（协议 media-protocol.md §2-8：浏览范围=接收目录+主目录，
            # /etc 等系统目录一律拒绝。清单旧预期「/etc/hosts 可下载」与协议不符，已按协议口径纠正）
            fin, body = await download(ws, col, comp["path"])
            ok_hosts = bool(fin) and fin.get("p") == "file.complete" \
                and sha256_hex(body) == fin.get("sha256") == sha256_hex(data)
            check("#7 下载白名单内文件（刚上传的）成功且 sha256 一致",
                  ok_hosts, f"{len(body)}B sha={fin and (fin.get('sha256') or '')[:16]}…")
            for sys_path in ("/etc/shadow", "/etc/hosts"):
                fin2, _ = await download(ws, col, sys_path)
                check(f"#7 下载 {sys_path}（系统目录）被拒 denied",
                      bool(fin2) and fin2.get("p") == "file.error" and fin2.get("reason") == "denied",
                      f"reason={fin2 and fin2.get('reason')} msg={fin2 and fin2.get('msg')}")

        # #11（控制端侧）：断开重连，agent 应因 peer.join 重发 hello
        await ws.close()
        await asyncio.sleep(2)
        async with websockets.connect(url, max_size=8 * 1024 * 1024) as ws2:
            col2 = Collector(ws2)
            col2.start()
            hello2 = await col2.wait_hello()
            check("#11 重进房间收到重发 hello（peer.join 触发）",
                  hello2 is not None,
                  f"mic={hello2 and hello2.get('mic')}（重连后 mic=OFF 契约点；JPEG 通路恒 false）")

    print()
    print("=" * 40)
    passed, total = sum(results), len(results)
    print(f"CHECKLIST: {passed}/{total} PASS")
    return 0 if passed == total else 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default="http://192.168.31.152:18443")
    ap.add_argument("--mobile", default="13800000001")
    ap.add_argument("--size-mb", type=int, default=100)
    ap.add_argument("--save-frame", default="")
    ap.add_argument("--skip-upload", action="store_true")
    a = ap.parse_args()
    sys.exit(asyncio.run(main(a)))
