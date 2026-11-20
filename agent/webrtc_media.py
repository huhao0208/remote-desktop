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
import threading
from typing import Any, Awaitable, Callable, Dict, Optional

import av
from aiortc import RTCConfiguration, RTCIceServer, RTCPeerConnection, RTCSessionDescription
from aiortc.mediastreams import VideoStreamTrack

from PIL import Image

# aiortc 的 H.264 码率被 MIN/MAX 夹住（500k–3M），直接调 setter 会被截断到 3 Mbps，
# 1080p 屏幕在 3 Mbps 下依然偏软。这里写私有字段绕过 clamp（内部实现，升级需复核）。
_ENC_PRIVATE_BITRATE = "_H264Encoder__target_bitrate"


class ScreenTrack(VideoStreamTrack):
    """把 mss 抓屏伪装成 WebRTC 视频轨。

    抓屏是阻塞调用（5–20ms），放到线程里跑，避免卡住 asyncio 事件循环；
    mss 实例按线程缓存（mss 不支持跨线程共享）。
    """

    kind = "video"

    def __init__(self, width: int = 1920, fps: int = 30) -> None:
        super().__init__()
        self.max_width = max(640, int(width))
        self.fps = max(1, min(60, int(fps)))
        self._tls = threading.local()
        self.frames = 0

    def _grab_sync(self):
        import mss

        sct = getattr(self._tls, "sct", None)
        if sct is None:
            sct = mss.mss()
            self._tls.sct = sct
        shot = sct.grab(sct.monitors[1])
        img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
        if img.width > self.max_width:
            h = max(2, int(img.height * self.max_width / img.width / 2) * 2)  # 偶数高度，H.264 要求
            img = img.resize((self.max_width, h), Image.BILINEAR)
        if img.width % 2 or img.height % 2:  # yuv420p 需要偶数宽高
            img = img.crop((0, 0, img.width - img.width % 2, img.height - img.height % 2))
        return img

    async def recv(self) -> av.VideoFrame:
        pts, time_base = await self.next_timestamp()
        img = await asyncio.to_thread(self._grab_sync)
        frame = av.VideoFrame.from_image(img)
        frame.pts = pts
        frame.time_base = time_base
        self.frames += 1
        return frame


class _Peer:
    """一个控制端的会话（PC + 视频轨 + 码率看门狗）。"""

    def __init__(self, pc: RTCPeerConnection, track: ScreenTrack) -> None:
        self.pc = pc
        self.track = track
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
    ) -> None:
        self._send_json = send_json
        self.width = width
        self.fps = fps
        self.bitrate_bps = max(1_000_000, int(bitrate_kbps) * 1000)
        self._on_state = on_state
        self._log = log
        self._peers: Dict[str, _Peer] = {}

    # ---------------------------------------------------------------- 状态

    @property
    def connected(self) -> bool:
        return any(p.state == "connected" for p in self._peers.values())

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
        if p.task:
            p.task.cancel()
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
        track = ScreenTrack(width=self.width, fps=self.fps)
        sess = _Peer(pc, track)
        self._peers[peer] = sess

        @pc.on("connectionstatechange")
        async def _on_state() -> None:
            sess.state = pc.connectionState
            self._log(f"[rtc] {peer} → {pc.connectionState}")
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
        answer = await pc.createAnswer()
        await pc.setLocalDescription(answer)
        await self._send_json({"p": "rtc.answer", "peer": peer,
                               "sdp": pc.localDescription.sdp,
                               "bitrate": self.bitrate_bps // 1000})
        self._log(f"[rtc] {peer} answer 已发（{self.width}w {self.fps}fps {self.bitrate_bps//1000}kbps）")
        sess.task = asyncio.create_task(self._bitrate_watchdog(sess))

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