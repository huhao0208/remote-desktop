"""被控端放音：把控制端推来的麦克风音轨送到系统扬声器（协议 v3 §6）。

与 `webrtc_media.MicTrack`（采集本机麦克风 → 推给控制端）方向相反，
两者互不影响，可以同时存在。

设计要点：
- **不额外引入依赖**：优先用已装好的 `sounddevice`（Agent 的音频采集本来就依赖它），
  没有就退到 `pyaudio`，再没有就 `available()=False`，`hello.mic=false`，
  控制端把麦克风按钮置灰——绝不因为没有放音能力就让整条链路降级。
- **回调里只做 append**：PortAudio 的音频回调运行在实时线程，
  任何阻塞（打日志、加复杂锁、resample）都会导致爆音/丢帧。
- **背压丢旧不丢新**：缓冲有上限，超了丢最早的块。喊话场景里延迟比完整性重要得多，
  宁可声音断一下，也不要越听越晚。
- **必须能真的关掉**：`close()` 关闭输出流并清空缓冲，否则被控端会一直占着扬声器，
  用户会以为被正常放音。

安全边界（对应协议 §6.5 规则 5）：本模块只负责放音，**不做静默放音**——
是否允许放音由上层（`agent.py` 的 `mic` 分支 + 本地可见提示）控制。
"""

from __future__ import annotations

import asyncio
import threading
import time
from collections import deque
from typing import Any, Optional

# 20ms @ 48kHz 单声道 s16 = 1920 字节。
FRAME_BYTES = 1920
SAMPLE_RATE = 48000

# 缓冲上限：500ms。喊话是实时交互，超过半秒的积压就该丢掉旧数据。
MAX_BUFFER_BYTES = SAMPLE_RATE * 2 // 2

# 优先 sounddevice（已随 requirements 装着），没有再试 pyaudio。
_BACKEND = ""
try:  # pragma: no cover - 环境相关
    import sounddevice as _sd  # type: ignore

    _BACKEND = "sounddevice"
except Exception:  # noqa: BLE001
    _sd = None  # type: ignore
    try:
        import pyaudio as _pa  # type: ignore

        _BACKEND = "pyaudio"
    except Exception:  # noqa: BLE001
        _pa = None  # type: ignore


def available() -> bool:
    """本机能否放音。false 时 `hello.mic=false`，控制端据此置灰按钮。"""
    return bool(_BACKEND)


def backend() -> str:
    """`sounddevice` / `pyaudio` / 空串。日志与 hello 里带上，排查用。"""
    return _BACKEND


class Speaker:
    """系统扬声器输出流。

    典型用法::

        spk = Speaker()
        if spk.start():
            await spk.feed(frame_bytes)   # 每收到一个远端音频帧就喂一次
        ...
        spk.close()

    线程安全：`write()` 可从任意线程调用（WebRTC 音频回调线程），
    `close()` 只能从事件循环线程调用。
    """

    def __init__(self, rate: int = SAMPLE_RATE, channels: int = 1) -> None:
        self.rate = int(rate or SAMPLE_RATE)
        self.channels = int(channels or 1)
        self._buf: deque = deque()
        self._buf_bytes = 0
        self._lock = threading.Lock()
        self._stream: Optional[Any] = None
        self._pya: Optional[Any] = None
        self._opened = False
        self.written = 0      # 已写入字节
        self.dropped = 0      # 因背压丢弃的字节
        self.underruns = 0    # 缓冲不足补静音的帧数
        self._warned = False

    # ------------------------------------------------------------ 生命周期

    def start(self) -> bool:
        """打开输出流。失败返回 False，调用方据此回 `mic.state{ok:false}`。"""
        if self._opened:
            return True
        if not _BACKEND:
            return False
        try:
            if _BACKEND == "sounddevice":
                self._stream = _sd.RawOutputStream(  # type: ignore[union-attr]
                    samplerate=self.rate,
                    channels=self.channels,
                    dtype="int16",
                    blocksize=FRAME_BYTES // 2 // self.channels,
                    callback=self._sd_callback,
                )
                self._stream.start()
            else:  # pyaudio
                self._pya = _pa.PyAudio()  # type: ignore[union-attr]
                self._stream = self._pya.open(
                    format=_pa.paInt16,  # type: ignore[union-attr]
                    channels=self.channels,
                    rate=self.rate,
                    frames_per_buffer=FRAME_BYTES // 2 // self.channels,
                    output=True,
                    stream_callback=self._pa_callback,
                )
                self._stream.start_stream()
            self._opened = True
            return True
        except Exception as e:  # noqa: BLE001
            # 设备被占用 / 无权限 / 无扬声器都走这里：不影响画面与其他功能
            print(f"[mic] 打开扬声器失败：{e}", flush=True)
            self._cleanup_stream()
            return False

    def close(self) -> None:
        """关闭输出流并清空缓冲。幂等。"""
        self._opened = False
        self._cleanup_stream()
        with self._lock:
            self._buf.clear()
            self._buf_bytes = 0

    def _cleanup_stream(self) -> None:
        stream, pya = self._stream, self._pya
        self._stream = None
        self._pya = None
        try:
            if stream is not None:
                if _BACKEND == "sounddevice":
                    stream.stop()
                    stream.close()
                else:
                    stream.stop_stream()
                    stream.close()
        except Exception:  # noqa: BLE001
            pass
        try:
            if pya is not None:
                pya.terminate()
        except Exception:  # noqa: BLE001
            pass

    # ------------------------------------------------------------ 写入

    def write(self, data: bytes) -> None:
        """写入一段 PCM（s16 单声道）。任意线程可调，不阻塞。

        超过缓冲上限时丢**最早**的块：喊话要的是「现在的声音」，
        积压只会让被控端听起来越来越滞后。
        """
        if not data or not self._opened:
            return
        n = len(data)
        with self._lock:
            self._buf.append(data)
            self._buf_bytes += n
            while self._buf_bytes > MAX_BUFFER_BYTES and len(self._buf) > 1:
                old = self._buf.popleft()
                self._buf_bytes -= len(old)
                self.dropped += len(old)
            self.written += n

    def _take(self, want: int) -> bytes:
        """取 want 字节；不足则补静音（保时间戳连续，避免爆音）。"""
        out = bytearray()
        with self._lock:
            while len(out) < want and self._buf:
                head = self._buf[0]
                need = want - len(out)
                if len(head) <= need:
                    out += head
                    self._buf.popleft()
                    self._buf_bytes -= len(head)
                else:
                    out += head[:need]
                    self._buf[0] = head[need:]
                    self._buf_bytes -= need
        if len(out) < want:
            self.underruns += 1
            out += b"\x00" * (want - len(out))
        return bytes(out)

    # ------------------------------------------------------------ 回调（实时线程）

    def _sd_callback(self, outdata, frames, time_info, status) -> None:  # noqa: ANN001
        # 实时线程：只允许 memcpy，绝不打日志/加复杂锁/异常外抛
        try:
            want = frames * self.channels * 2
            outdata[:] = self._take(want)
        except Exception:  # noqa: BLE001
            try:
                outdata.fill(0)
            except Exception:  # noqa: BLE001
                pass

    def _pa_callback(self, in_data, frame_count, time_info, status):  # noqa: ANN001
        try:
            want = frame_count * self.channels * 2
            return (self._take(want), _pa.paContinue)  # type: ignore[union-attr]
        except Exception:  # noqa: BLE001
            return (b"\x00" * (frame_count * self.channels * 2), _pa.paContinue)  # type: ignore[union-attr]


class RemoteAudioSink:
    """消费 aiortc 的 `RemoteAudioTrack`，把 PCM 转成 s16 单声道喂给 [Speaker]。

    aiortc 送来的是 `av.AudioFrame`（常见 s16 立体声或 fltp）。这里统一转成
    s16 单声道——扬声器输出流也是这个格式，避免在实时回调里做重采样。

    **不需要 av 也能 import**（`av` 只在 `feed` 里用到具体帧对象的方法），
    这样单测可以在没装 aiortc/av 的机器上跑。
    """

    def __init__(self, speaker: Speaker) -> None:
        self.speaker = speaker
        self.frames = 0
        self._stopped = False
        # 放音门控：返回 False 时帧被消费但不出声。
        # 上层用它实现「未点开麦前绝不静默放音」（协议 §6.5 规则 5）。
        self.gate: Optional[Any] = None

    async def run(self, track) -> None:  # noqa: ANN001
        """持续从 track 取帧。track 结束/异常时返回，由调用方决定是否重开。

        注意：**无论 gate 是否放行都要把帧消费掉**。若不消费，aiortc 的接收缓冲
        会一直堆积，等到用户真的开麦时，听到的是几秒前的旧声音。
        """
        while not self._stopped:
            try:
                frame = await track.recv()
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                # MediaStreamError：对端关了轨或断链，正常收尾
                break
            self.feed(frame)

    def feed(self, frame) -> None:  # noqa: ANN001
        """把一个 av.AudioFrame 转成 s16 单声道并写入扬声器。"""
        try:
            if self.gate is not None and not self.gate():
                return  # 已消费、不放音
            arr = _to_s16_mono(frame)
            if arr is None:
                return
            self.speaker.write(arr)
            self.frames += 1
        except Exception:  # noqa: BLE001
            # 单帧转换失败不能让整条语音断掉
            return

    def stop(self) -> None:
        self._stopped = True


def _to_s16_mono(frame) -> Optional[bytes]:  # noqa: ANN001
    """av.AudioFrame → s16 单声道 bytes。失败返回 None（不抛）。"""
    try:
        # av.AudioFrame 的 to_ndarray() 需要 numpy；没有就退回 to_bytes（仅 s16 可用）
        try:
            import numpy as np  # type: ignore

            arr = frame.to_ndarray()
            # 形状可能是 (channels, samples) 或 (1, samples*channels)，按 layout 判断
            if arr.ndim == 2 and arr.shape[0] > 1:
                arr = arr.mean(axis=0)  # 混成单声道
            if arr.dtype != np.int16:
                # fltp 等浮点格式：钳到 [-1,1] 再转 int16
                flat = np.clip(arr.reshape(-1), -1.0, 1.0) if arr.dtype.kind == "f" \
                    else np.clip(arr.reshape(-1), -32768, 32767)
                arr = (flat * 32767).astype(np.int16) if arr.dtype.kind == "f" \
                    else flat.astype(np.int16)
            else:
                arr = arr.reshape(-1)
            return arr.tobytes()
        except ImportError:
            if getattr(frame.format, "name", "") != "s16":
                return None
            return frame.to_bytes()
    except Exception:  # noqa: BLE001
        return None