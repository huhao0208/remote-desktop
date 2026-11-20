"""WebRTC 媒体通道：屏幕 → H.264 → SRTP/UDP（aiortc）。

设计约束与取舍：
- 信令复用现有 `/ws/signaling` 文本帧透传，**服务端零改动**（SDP/ICE 当普通 JSON 转发）
- 清晰度优先：默认 8 Mbps，且绕过 aiortc 的 3 Mbps 硬上限（其 MAX_BITRATE 常量）
- 接收端负责「宁可掉帧不降分辨率」，发送端不主动降采样
- **按对端隔离会话**：同一房间可能有多个控制端（手机+电脑），
  每个 peer 独立一条 PC，互不踢线；最后一个断开才恢复 JPEG 兜底
- JPEG-over-WS 保留为兜底：WebRTC 没连上或失败时无缝回落

为什么不用逐帧 JPEG：屏幕内容用 H.264 帧间预测，静止画面几乎不占带宽，
同码率下 PSNR 比 JPEG 高 8–12 dB（实测见 docs/media-protocol.md）。
"""
from __future__ import annotations

import asyncio
import fractions
import platform
import threading
import time
from collections import deque
from typing import Any, Awaitable, Callable, Dict, Optional

import av
from aiortc import RTCConfiguration, RTCIceServer, RTCPeerConnection, RTCSessionDescription
from aiortc.mediastreams import AudioStreamTrack, MediaStreamError, VideoStreamTrack

from PIL import Image

try:  # 脚本直跑与包内导入都要能用
    from .screens import list_monitors
except ImportError:
    from screens import list_monitors

SYSTEM = platform.system()  # Windows / Darwin / Linux

# aiortc 的 H.264 码率被 MIN/MAX 夹住（500k–3M），直接调 setter 会被截断到 3 Mbps，
# 1080p 屏幕在 3 Mbps 下依然偏软。这里写私有字段绕过 clamp（内部实现，升级需复核）。
_ENC_PRIVATE_BITRATE = "_H264Encoder__target_bitrate"


def new_mss():
    """mss 10 起 mss.mss() 被弃用（会刷 DeprecationWarning）。"""
    import mss

    return mss.MSS() if hasattr(mss, "MSS") else mss.mss()


def usable_monitors() -> list:
    """可用显示器列表（mss 不可用时自动回落到 Quartz，返回项含 source 字段）。"""
    return list_monitors()


class ScreenTrack(VideoStreamTrack):
    """把屏幕抓取伪装成 WebRTC 视频轨。

    抓屏是阻塞调用（5–20ms），放到线程里跑，避免卡住 asyncio 事件循环；
    mss 实例按线程缓存（mss 不支持跨线程共享）。

    `monitor` 是 `sct.monitors[1:]` 的下标（0 = 主屏），与 Agent 下发的
    `screens.list[].id` 一一对应；多屏切换时整体重建本轨（分辨率变了）。

    健壮性（本地实测过：无授权时 mss 会卡 30s，且阻塞期间持 GIL，
    整条链路会一起停摆）：
    - 启动自检：没显示器/没授权 → 记 `screen_permission`，进程不退出
    - 抓屏看门狗：单次抓屏超时 3s 就跳过该帧，且**不并发堆积**新抓屏线程
    - 降级后端：macOS 上 mss 超时/失败后切 `screencapture`（ImageGrab，走另一条
      TCC 通道，实测 0.15–0.39s）
    """

    kind = "video"
    GRAB_TIMEOUT = 3.0

    def __init__(self, width: int = 1920, fps: int = 30, monitor: int = 0,
                 on_error: Optional[Callable[[str], None]] = None,
                 log: Optional[Callable[[str], None]] = None) -> None:
        super().__init__()
        self.max_width = max(640, int(width))
        self.fps = max(1, min(60, int(fps)))
        self.monitor = max(0, int(monitor))
        self._tls = threading.local()
        self._log = log or (lambda m: print(m, flush=True))
        self._on_error = on_error
        self.backend = "mss"  # mss | pil（pil = macOS screencapture 通道）
        self.sent = 0
        self.grab_fail = 0
        self.grab_timeout = 0
        self._pending: Optional[asyncio.Task] = None  # 在飞的抓屏线程
        self._ready: Optional[Image.Image] = None     # 抓到但还没送出的图
        self._last: Optional[Image.Image] = None      # 上一张成功帧（超时时复制）
        self._notified: set = set()
        self.available = self._check_screen()

    # ------------------------------------------------------------ 自检/告警

    def _notify(self, err: str) -> None:
        """同一种错误只上报一次，避免刷屏。"""
        if err in self._notified:
            return
        self._notified.add(err)
        if self._on_error:
            try:
                self._on_error(err)
            except Exception:
                pass

    def _check_screen(self) -> bool:
        mons = list_monitors()
        if not mons:
            self._log("[agent] 无可用显示器或缺少屏幕录制授权（monitors 为空）")
            self._notify("screen_permission")
            return False
        if self.monitor >= len(mons):
            self.monitor = 0
        if mons[0].get("source") == "quartz":
            # mss 的显示器列表被 TCC 挡住（0×0），但 screencapture 通道仍可用
            self.backend = "pil"
            self._log("[agent] mss 不可用（TCC），改用 ImageGrab(screencapture) 抓屏")
        return True

    def _on_timeout(self) -> None:
        self.grab_timeout += 1
        if self.grab_timeout == 1 or self.grab_timeout % 10 == 0:
            self._log(f"[agent] 抓屏超时 {self.grab_timeout} 次（>{self.GRAB_TIMEOUT:.0f}s），跳过该帧")
        if self.grab_timeout == 1:
            self._notify("screen_timeout")
        # macOS：mss 走 CGWindowList，无授权/无显示时会一直卡；
        # 切到 screencapture 通道（ImageGrab），并放弃卡住的那次抓屏（只切一次）
        if self.backend == "mss" and SYSTEM == "Darwin":
            self.backend = "pil"
            self._log("[agent] 抓屏超时，切到 ImageGrab(screencapture) 后端")
            if self._pending is not None:
                self._pending.add_done_callback(_swallow)
                self._pending = None  # 丢弃结果，避免下一帧继续等它

    # ------------------------------------------------------------ 抓屏（线程内）

    def _monitor_box(self) -> Optional[tuple]:
        """当前显示器的 (left, top, right, bottom)，screencapture -R 用。"""
        mons = list_monitors()
        if self.monitor < len(mons):
            m = mons[self.monitor]
            return (m["left"], m["top"], m["left"] + m["width"], m["top"] + m["height"])
        return None

    def _grab_mss(self) -> Image.Image:
        sct = getattr(self._tls, "sct", None)
        if sct is None:
            sct = new_mss()
            self._tls.sct = sct
        mons = [m for m in sct.monitors[1:] if m["width"] > 0 and m["height"] > 0]
        if not mons:
            raise RuntimeError("no usable monitor")
        # 显示器可能在运行中被拔掉：越界退回主屏，不让推流断
        mon = mons[min(self.monitor, len(mons) - 1)]
        shot = sct.grab(mon)
        return Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")

    def _grab_pil(self) -> Image.Image:
        from PIL import ImageGrab

        box = self._monitor_box()
        return ImageGrab.grab(bbox=box) if box else ImageGrab.grab()

    def _grab_sync(self) -> Image.Image:
        try:
            img = self._grab_mss() if self.backend == "mss" else self._grab_pil()
        except Exception as e:
            if self.backend == "mss" and SYSTEM == "Darwin":
                self.backend = "pil"
                self._log(f"[agent] mss 抓屏失败（{e}），切到 ImageGrab(screencapture) 后端")
                img = self._grab_pil()
            else:
                raise
        if img.width > self.max_width:
            h = max(2, int(img.height * self.max_width / img.width / 2) * 2)  # 偶数高度，H.264 要求
            img = img.resize((self.max_width, h), Image.BILINEAR)
        if img.width % 2 or img.height % 2:  # yuv420p 需要偶数宽高
            img = img.crop((0, 0, img.width - img.width % 2, img.height - img.height % 2))
        self._last = img
        return img

    # ------------------------------------------------------------ 取帧

    async def _next_image(self) -> Optional[Image.Image]:
        # 1) 上一次超时后仍在跑的抓屏完成了？收下结果，避免线程越积越多
        if self._pending is not None and self._pending.done():
            try:
                self._ready = self._pending.result()
            except Exception:
                self.grab_fail += 1
            self._pending = None
        if self._ready is not None:
            img, self._ready = self._ready, None
            return img
        # 2) 上一次还卡着：直接用上一帧，不再起新线程（否则每帧泄漏一个 30s 线程）
        if self._pending is not None:
            self._on_timeout()
            return None
        # 3) 起一次抓屏，带看门狗
        self._pending = asyncio.create_task(asyncio.to_thread(self._grab_sync))
        try:
            img = await asyncio.wait_for(asyncio.shield(self._pending), timeout=self.GRAB_TIMEOUT)
        except asyncio.TimeoutError:
            self._on_timeout()
            return None
        except Exception:
            self.grab_fail += 1
            self._pending = None
            return None
        self._pending = None
        return img

    async def recv(self) -> av.VideoFrame:
        pts, time_base = await self.next_timestamp()
        img = await self._next_image()
        if img is None:  # 抓不到就复制上一帧，画面定格而不是断流/黑屏
            img = self._last
        if img is None:  # 一帧都没成功过：给个占位深色帧，保证编码器有时钟
            img = Image.new("RGB", (640, 360), (18, 18, 20))
        frame = av.VideoFrame.from_image(img)
        frame.pts = pts
        frame.time_base = time_base
        self.sent += 1
        return frame


def _swallow(fut: asyncio.Future) -> None:
    """丢弃被放弃的抓屏线程结果，避免 asyncio 打 'exception was never retrieved'。"""
    if fut.cancelled():
        return
    try:
        fut.exception()
    except BaseException:
        pass


class MicTrack(AudioStreamTrack):
    """系统默认输入设备 → WebRTC 音频轨（s16 单声道，交给 Opus 编码）。

    采集用 sounddevice 的 RawInputStream 回调写环形缓冲（回调里只做 append，
    不能阻塞）；recv() 按 20ms 一帧取，缓冲不足时补静音，保证时间戳连续。
    设备打不开（未授权麦克风/被占用/无设备）时 `start()` 返回 False，
    上层不挂轨并让 hello.audio=false，绝不因音频崩掉整条链路。

    注：系统内录（采集「正在播放的声音」）需要 macOS 装 BlackHole 之类虚拟
    声卡并把 `--audio-device` 指向它，首版仅支持输入设备。
    """

    kind = "audio"
    SAMPLES = 960  # 20ms @ 48kHz

    def __init__(self, rate: int = 48000, device: Optional[Any] = None) -> None:
        super().__init__()
        self.rate = int(rate or 48000)
        self.device = device
        self._chunks: deque = deque()
        self._bytes = 0
        self._lock = threading.Lock()
        self._stream = None
        self._pts = 0
        self.frames = 0
        self.dropped = 0
        self._max_bytes = self.rate * 2 // 2  # 500ms 上限，超了丢最旧

    def start(self) -> bool:
        try:
            import sounddevice as sd

            def _cb(indata, frames, _t, status):  # noqa: ANN001
                with self._lock:
                    self._chunks.append(bytes(indata))
                    self._bytes += len(indata)
                    while self._bytes > self._max_bytes and self._chunks:
                        self._bytes -= len(self._chunks.popleft())
                        self.dropped += 1

            self._stream = sd.RawInputStream(
                samplerate=self.rate, channels=1, dtype="int16",
                device=self.device, callback=_cb,
            )
            self._stream.start()
            return True
        except Exception:
            self._stream = None
            return False

    def stop(self) -> None:
        try:
            if self._stream:
                self._stream.stop()
                self._stream.close()
        except Exception:
            pass
        self._stream = None
        super().stop()

    def _take(self, need: int) -> bytes:
        with self._lock:
            if self._bytes < need:
                return b""
            data = b"".join(self._chunks)
            self._chunks.clear()
            self._bytes = 0
            if len(data) > need:
                self._chunks.append(data[need:])
                self._bytes = len(data) - need
            return data[:need]

    async def recv(self) -> av.AudioFrame:
        if self.readyState != "live":
            raise MediaStreamError
        need = self.SAMPLES * 2
        if self._stream is None:
            await asyncio.sleep(0.02)  # 无设备时仍按实时节奏出静音
            data = b""
        else:
            data = self._take(need)
            deadline = time.monotonic() + 0.03
            while not data and time.monotonic() < deadline:
                await asyncio.sleep(0.004)
                data = self._take(need)
        if len(data) < need:
            data = data + b"\x00" * (need - len(data))

        frame = av.AudioFrame(format="s16", layout="mono", samples=self.SAMPLES)
        frame.planes[0].update(data)
        frame.sample_rate = self.rate
        frame.time_base = fractions.Fraction(1, self.rate)
        frame.pts = self._pts
        self._pts += self.SAMPLES
        self.frames += 1
        return frame


class _Peer:
    """一个控制端的会话（PC + 视频轨 + 音频轨 + 码率看门狗）。"""

    def __init__(self, pc: RTCPeerConnection, track: ScreenTrack) -> None:
        self.pc = pc
        self.track = track
        self.mic: Optional[MicTrack] = None
        self.task: Optional[asyncio.Task] = None
        self.state = "new"


class WebRTCMedia:
    """房间内的多条 WebRTC 会话，按 peer 隔离。"""

    def __init__(
        self,
        send_json: Callable[[Dict[str, Any]], Awaitable[None]],
        width: int = 1920,
        fps: int = 30,
        bitrate_kbps: int = 8000,
        on_state: Optional[Callable[[str], None]] = None,
        log: Callable[[str], None] = print,
        audio: bool = True,
        audio_device: Optional[Any] = None,
        monitor: int = 0,
        screen_count: int = 1,
    ) -> None:
        self._send_json = send_json
        self.width = width
        self.fps = fps
        self.bitrate_bps = max(1_000_000, int(bitrate_kbps) * 1000)
        self._on_state = on_state
        self._log = log
        self._peers: Dict[str, _Peer] = {}
        self.monitor = max(0, int(monitor))
        self.screen_count = max(1, int(screen_count))
        self.enable_audio = bool(audio)
        self.audio_device = audio_device
        self.audio_rate = 48000
        self.audio_ok = self._probe_audio() if self.enable_audio else False

    # ---------------------------------------------------------------- 状态

    def _probe_audio(self) -> bool:
        """启动时真开一次麦克风：设备缺失/未授权/被占用都在这里暴露，返回 False。"""
        try:
            import sounddevice as sd
        except Exception as e:
            self._log(f"[rtc] 未安装 sounddevice（{e}），音频关闭")
            return False
        try:
            info = sd.query_devices(self.audio_device, "input")
            self.audio_rate = int(info.get("default_samplerate") or 48000)
            try:
                sd.check_input_settings(device=self.audio_device, channels=1,
                                        samplerate=48000, dtype="int16")
                self.audio_rate = 48000
            except Exception:
                pass  # 设备不支持 48k，用默认采样率，Opus 编码器内部会重采样
            probe = sd.RawInputStream(samplerate=self.audio_rate, channels=1,
                                      dtype="int16", device=self.audio_device)
            probe.start()
            probe.stop()
            probe.close()
            self._log(f"[rtc] 音频设备就绪（{info.get('name')} @{self.audio_rate}Hz）")
            return True
        except Exception as e:
            self._log(f"[rtc] 音频不可用（{e}），audio=false")
            return False

    @property
    def connected(self) -> bool:
        return any(p.state == "connected" for p in self._peers.values())

    def _emit_error(self, err: str) -> None:
        """抓屏类错误上报控制端：`agent.error{err:"screen_permission"|"screen_timeout"}`。"""
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return
        loop.create_task(self._send_json({"p": "agent.error", "err": err}))

    def _publish_state(self) -> None:
        if not self._on_state:
            return
        live = self.connected
        self._on_state("connected" if live else ("closed" if not self._peers else "connecting"))

    # ---------------------------------------------------------------- 生命周期

    async def _close_peer(self, peer: str) -> None:
        p = self._peers.pop(peer, None)
        if not p:
            return
        # 排查「协商成功但 0 帧」：关会话时打一行发送统计（稳态零噪声）
        if p.track is not None:
            self._log(f"[rtc] {peer} 关闭：已发 {p.track.sent} 帧"
                      f"（抓屏失败 {p.track.grab_fail}、超时 {p.track.grab_timeout}，"
                      f"{p.track.max_width}w {p.track.fps}fps "
                      f"@显示器{p.track.monitor}/{p.track.backend}）")
        if p.task:
            p.task.cancel()
        if p.mic:
            self._log(f"[rtc] {peer} 音频已发 {p.mic.frames} 帧，丢弃 {p.mic.dropped} 块")
            p.mic.stop()
        try:
            await p.pc.close()
        except Exception:
            pass
        self._publish_state()

    async def close(self) -> None:
        for peer in list(self._peers):
            await self._close_peer(peer)

    # ---------------------------------------------------------------- 协商

    async def handle_offer(self, sdp: str, ice: Optional[list] = None, peer: str = "default") -> None:
        """收到某控制端的 offer：建 PC、挂屏幕轨、回 answer。同 peer 重复 offer 视为重协商。"""
        await self._close_peer(peer)

        pc = RTCPeerConnection(RTCConfiguration(iceServers=_parse_ice(ice)))
        track = ScreenTrack(width=self.width, fps=self.fps, monitor=self.monitor,
                            on_error=self._emit_error, log=self._log)
        sess = _Peer(pc, track)
        self._peers[peer] = sess

        @pc.on("connectionstatechange")
        async def _on_state() -> None:
            sess.state = pc.connectionState
            # 带上实际生效的画质参数：排查 stream.config 是否真落到 track 上
            self._log(f"[rtc] {peer} → {pc.connectionState}"
                      f"（{sess.track.max_width}w {sess.track.fps}fps "
                      f"{self.bitrate_bps // 1000}kbps 显示器{sess.track.monitor}）")
            if pc.connectionState in ("failed", "closed"):
                # 只清理「自己」——同 peer 的重复 offer 会先建新会话，
                # 旧会话的 closed 回调用 peer 键去关，会把新会话误杀。
                if self._peers.get(peer) is sess:
                    await self._close_peer(peer)
            else:
                self._publish_state()

        @pc.on("icecandidate")
        async def _on_candidate(candidate) -> None:  # noqa: ANN001
            if candidate is None:
                return
            await self._send_json({
                "p": "rtc.ice",
                "peer": peer,
                "candidate": candidate.candidate,
                "sdpMid": candidate.sdpMid,
                "sdpMLineIndex": candidate.sdpMLineIndex,
            })

        pc.addTrack(track)
        await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp, type="offer"))
        # 音频：只有对端 SDP 里确实有 m=audio 才挂轨——answer 不能新增 m-line，
        # 硬加会让协商失败。addTrack 会复用 offer 建出的那条 recvonly 传输。
        if self.audio_ok and "m=audio" in sdp:
            mic = MicTrack(rate=self.audio_rate, device=self.audio_device)
            if mic.start():
                pc.addTrack(mic)
                sess.mic = mic
            else:
                self._log("[rtc] 麦克风打开失败，本次仅推视频")
        answer = await pc.createAnswer()
        await pc.setLocalDescription(answer)
        await self._send_json({"p": "rtc.answer", "peer": peer,
                               "sdp": pc.localDescription.sdp,
                               "bitrate": self.bitrate_bps // 1000})
        kinds = "视频+音频" if sess.mic else "仅视频"
        self._log(f"[rtc] {peer} answer 已发（{kinds} {self.width}w {self.fps}fps "
                  f"{self.bitrate_bps//1000}kbps）")
        sess.task = asyncio.create_task(self._bitrate_watchdog(sess))

    async def select_screen(self, idx: int) -> int:
        """切显示器：重建视频轨（分辨率变了）并强制关键帧，无需重新协商。

        - pts 从旧轨续上，否则 RTP 时间戳会回跳，浏览器解码花屏
        - 新旧分辨率不同时 aiortc 会重建编码器（天然 IDR + 新 SPS/PPS）；
          相同时显式 `_send_keyframe()`，保证控制端下一帧就能出画
        """
        self.monitor = max(0, min(int(idx), self.screen_count - 1))
        for sess in self._peers.values():
            old = sess.track
            new = ScreenTrack(width=self.width, fps=self.fps, monitor=self.monitor,
                              on_error=self._emit_error, log=self._log)
            for attr in ("_start", "_timestamp"):  # 续接时间轴
                if hasattr(old, attr):
                    try:
                        setattr(new, attr, getattr(old, attr))
                    except Exception:
                        pass
            for sender in sess.pc.getSenders():
                if sender.track is old:
                    sender.replaceTrack(new)
                    try:
                        sender._send_keyframe()  # 下一帧强制 IDR
                    except Exception:
                        pass
            sess.track = new
            # 旧轨不 stop()：sender 可能正 await 它取帧，stop 会抛错并终止 RTP 任务
        self._log(f"[rtc] 切换到显示器 {self.monitor}，已请求关键帧")
        return self.monitor

    async def handle_ice(self, candidate: str, sdp_mid: Optional[str], sdp_mline: Optional[int],
                         peer: str = "default") -> None:
        sess = self._peers.get(peer) or next(iter(self._peers.values()), None)
        if not sess or not candidate:
            return
        try:
            # 浏览器给的是 SDP 字符串（"candidate:1 1 udp ..."），
            # aiortc 的构造器不接受 candidate= 关键字，必须用解析器
            from aiortc.sdp import candidate_from_sdp

            cand = candidate_from_sdp(candidate)
            cand.sdpMid = sdp_mid
            cand.sdpMLineIndex = sdp_mline
            await sess.pc.addIceCandidate(cand)
        except Exception as e:  # 单个候选失败不影响其它候选
            self._log(f"[rtc] addIce 失败: {e}")

    async def _bitrate_watchdog(self, sess: _Peer) -> None:
        """把编码器码率钉在目标值。

        REMB 反馈会按对端估算压低码率（aiortc 默认 1 Mbps），对屏幕内容过于保守。
        这里每 2s 重新抬高一次，保证清晰度；真拥塞时表现为掉帧而非降分辨率。
        """
        try:
            while True:
                await asyncio.sleep(2)
                if sess.pc.connectionState not in ("connected", "connecting"):
                    return
                for sender in sess.pc.getSenders():
                    enc = getattr(sender, "_RTCRtpSender__encoder", None)
                    if enc is None:
                        continue
                    try:
                        setattr(enc, _ENC_PRIVATE_BITRATE, self.bitrate_bps)
                    except Exception:
                        try:
                            enc.target_bitrate = self.bitrate_bps
                        except Exception:
                            pass
        except asyncio.CancelledError:
            return

    # ---------------------------------------------------------------- 运行时调参

    def set_config(self, width: Optional[int] = None, fps: Optional[int] = None,
                   bitrate_kbps: Optional[int] = None) -> None:
        if width:
            self.width = max(640, min(3840, int(width)))
        if fps:
            self.fps = max(1, min(60, int(fps)))
        if bitrate_kbps:
            self.bitrate_bps = max(1000, int(bitrate_kbps)) * 1000
        for sess in self._peers.values():
            sess.track.max_width = self.width
            sess.track.fps = self.fps


def _parse_ice(raw: Optional[list]) -> list:
    """控制端下发的 ice 配置（服务端 room_config.ice_servers）转 RTCIceServer。

    兼容两种形态：
      {"stun": ["stun:host:3478"], "turn": [{"urls": "...", "username": "...", "credential": "..."}]}
      [{"urls": ["..."], "username": "...", "credential": "..."}]
    """
    out: list = []
    if not raw:
        return out
    if isinstance(raw, dict):
        for url in raw.get("stun") or []:
            out.append(RTCIceServer(urls=[url]))
        for turn in raw.get("turn") or []:
            if isinstance(turn, dict) and turn.get("urls"):
                urls = turn["urls"]
                out.append(RTCIceServer(
                    urls=[urls] if isinstance(urls, str) else list(urls),
                    username=turn.get("username"),
                    credential=turn.get("credential"),
                ))
        return out
    for item in raw:
        if isinstance(item, dict) and item.get("urls"):
            urls = item["urls"]
            out.append(RTCIceServer(
                urls=[urls] if isinstance(urls, str) else list(urls),
                username=item.get("username"),
                credential=item.get("credential"),
            ))
    return out