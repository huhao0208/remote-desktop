import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../core/models.dart';
import '../signaling/signaling_client.dart';

/// 一帧画面（目前只有 JPEG 通路会产生）。
class FramePacket {
  const FramePacket({required this.bytes, this.latency = Duration.zero});

  final Uint8List bytes;

  /// Agent 采集时间戳 → 本地收到的端到端延迟（FRM1 头里有 8B 毫秒时间戳）。
  final Duration latency;
}

/// 媒体通路抽象。
///
/// 页面只依赖这个接口：`agent.hello` 里 `media == "webrtc"` 时换成
/// [WebRtcTransport]，页面代码一行不用改（P0-3）。
abstract class MediaTransport {
  /// `jpeg` | `webrtc`，与协议的 `media` 字段取值一致。
  String get kind;

  /// 给 HUD 用的中文标签。
  String get label;

  Stream<FramePacket> get frames;

  Future<void> start({
    required AgentHello hello,
    required RoomConfig room,
    required SignalingClient signaling,
  });

  /// 画面区域。JPEG 通路用 `Image.memory`（**临时方案**）；WebRTC 通路应返回
  /// `Texture`/`RTCVideoView`。
  Widget buildView({required BoxFit fit});

  Future<void> dispose();
}

/// 未收到首帧 / 通路不可用时的占位视图。
class MediaPlaceholder extends StatelessWidget {
  const MediaPlaceholder({required this.text, this.showSpinner = true, super.key});

  final String text;
  final bool showSpinner;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (showSpinner) ...<Widget>[
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            const SizedBox(height: 14),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF8B949E), fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}