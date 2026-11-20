import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
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

/// 通路的实时统计，只给 HUD 用。
///
/// JPEG 通路的 fps 由页面自己数帧；WebRTC 没有帧流（画面在原生纹理里），只能读
/// `pc.getStats()` 的 `inbound-rtp`，所以统一从这个结构体出。
class TransportStats {
  const TransportStats({this.fps, this.width = 0, this.height = 0});

  /// `null` = 还没统计到（尚未收到首帧）→ HUD 显示 `—`，不要显示 `0 fps`
  /// 让人误判成「卡住」。
  final int? fps;

  /// 解码后的实际画面尺寸（协议 §7：必须等于 `stream.config.width`，不因带宽缩）
  final int width;
  final int height;

  bool get hasVideo => width > 0 && height > 0;
}

/// 媒体通路抽象。
///
/// 页面只依赖这个接口：`agent.hello` 里 `media == "webrtc"` 时换成
/// [WebRtcTransport]，页面只多读一个 [stats]（HUD），其余逻辑不变。
abstract class MediaTransport {
  /// `jpeg` | `webrtc`，与协议的 `media` 字段取值一致。
  String get kind;

  /// 给 HUD 用的中文标签。
  String get label;

  Stream<FramePacket> get frames;

  /// WebRTC 专用统计源；JPEG 通路返回 `null`（页面按帧流自己数 fps）。
  ValueListenable<TransportStats>? get stats => null;

  /// 远端音频轨是否已经挂上（协议 v2 §1）。JPEG 通路恒为 false。
  ///
  /// 页面用它决定要不要显示 🔊/🔇：**只有 hello.audio 为真且真的收到轨**才显示，
  /// 缺音频绝不影响视频通路（不走 fallback）。
  bool get hasAudio => false;

  /// 本地静音（只改本机音量，**不通知 Agent**，协议 v2 §1）。
  Future<void> setAudioMuted(bool muted) async {}

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