import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/models.dart';
import '../signaling/signaling_client.dart';
import 'media_transport.dart';

/// WebRTC（H.264/SRTP over UDP）通路占位实现。
///
/// v1 骨架只留接口，保证页面无需改动即可切换。接入步骤（P0-3）：
///
/// 1. `pubspec.yaml` 增加 `flutter_webrtc`；平台侧需开相机/麦克风权限 **不需要**
///    （纯接收），但 macOS 需在 `macos/Runner/*.entitlements` 打开
///    `com.apple.security.network.client`（模板默认已开）。
/// 2. 建 PC：
///    ```dart
///    final pc = await createPeerConnection(<String, dynamic>{
///      'iceServers': room.iceServers, // 服务端 room_config.ice_servers 原样透传
///    });
///    ```
/// 3. 只收不发：
///    ```dart
///    final transceiver = await pc.addTransceiver(
///      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
///      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
///    );
///    // 关键：宁可掉帧也不降分辨率（协议 §3）
///    await transceiver.setCodecPreferences(...);
///    ```
/// 4. `createOffer()` → 发送 `{"p":"rtc.offer","sdp":sdp,"ice":room_config.ice_servers}`；
/// 5. 监听信令 `rtc.answer` → `pc.setRemoteDescription`；
///    `rtc.ice` → `pc.addCandidate(RTCIceCandidate(...))`；
///    `pc.onIceCandidate` → 发送 `{"p":"rtc.ice","candidate":...,"sdpMid":...,"sdpMLineIndex":...}`；
/// 6. `pc.onTrack` → `RTCVideoRenderer`（`initialize()` + `srcObject = stream`），
///    `buildView` 返回 `RTCVideoView(renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)`；
/// 7. `pc.onConnectionState`：`failed/disconnected` → 通知页面回落 [JpegTransport]；
/// 8. `buildView` 必须返回 `Texture`/`RTCVideoView`，**不要**再用 `Image.memory`。
class WebRtcTransport implements MediaTransport {
  final StreamController<FramePacket> _frames = StreamController<FramePacket>.broadcast();

  @override
  String get kind => 'webrtc';

  @override
  String get label => 'H.264 / WebRTC（待接入）';

  @override
  Stream<FramePacket> get frames => _frames.stream;

  @override
  Future<void> start({
    required AgentHello hello,
    required RoomConfig room,
    required SignalingClient signaling,
  }) async {
    throw UnsupportedError('WebRTC 通路尚未实现（P0-3），请先使用 JPEG 兜底通路');
  }

  @override
  Widget buildView({required BoxFit fit}) =>
      const MediaPlaceholder(text: 'H.264 通路待接入（P0-3）', showSpinner: false);

  @override
  Future<void> dispose() async {
    await _frames.close();
  }
}