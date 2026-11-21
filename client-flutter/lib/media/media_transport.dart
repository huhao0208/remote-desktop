import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../core/mic_switch.dart';
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
  const TransportStats({
    this.fps,
    this.width = 0,
    this.height = 0,
    this.rttMs,
    this.bitrateKbps,
    this.lossPercent,
    this.jitterMs,
    this.jitterBufferMs,
    this.dropped,
    this.codec,
    this.iceType,
  });

  /// `null` = 还没统计到（尚未收到首帧）→ HUD 显示 `—`，不要显示 `0 fps`
  /// 让人误判成「卡住」。
  final int? fps;

  /// 解码后的实际画面尺寸（协议 §7：必须等于 `stream.config.width`，不因带宽缩）
  final int width;
  final int height;

  /// 以下字段只给「连接信息面板」用（`docs/远控复刻基线.md` P0-2）。
  /// 全部可为 `null`：平台/插件版本不同，`getStats()` 不一定有这些键，
  /// **不要用 0 兜底**——面板上「—」和「0 ms」是两件事。
  final int? rttMs;

  /// 接收码率（kbps），由 `bytesReceived` 增量按秒折算。
  final int? bitrateKbps;

  /// 丢包率（0–100），来自 `packetsLost / (packetsLost + packetsReceived)`。
  final double? lossPercent;

  /// 网络抖动（ms），`inbound-rtp.jitter` 直接是秒。
  final int? jitterMs;

  /// 抖动缓冲深度（ms），`jitterBufferDelay / jitterBufferEmittedCount`。
  final int? jitterBufferMs;

  /// 累计丢帧（`framesDropped`，解码侧）。
  final int? dropped;

  /// 编码格式（`video/H264` → `H.264`）。
  final String? codec;

  /// 选中的候选对类型：`host` / `srflx` / `prflx` / `relay`。
  /// `host` = 局域网直连，`relay` = TURN 中转。
  final String? iceType;

  bool get hasVideo => width > 0 && height > 0;

  /// 直连 / 中转的中文说明（官方文案：局域网直连 / 安全中转连接）。
  String get connectionPathLabel {
    switch (iceType) {
      case 'host':
        return '局域网直连';
      case 'srflx':
      case 'prflx':
        return 'P2P 直连（NAT 穿透）';
      case 'relay':
        return '安全中转连接';
      default:
        return '—';
    }
  }
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

  /// 本通路能否推麦克风（协议 v3 §6）。JPEG 通路恒为 false：没有 RTP 通路可挂。
  bool get canSendMic => false;

  /// 打开本地麦克风并推到被控端。
  ///
  /// 返回 null = 成功；否则是失败原因（[MicError]）。**不抛异常**：
  /// 调用方（页面）拿到错误码后弹回开关，异常穿透只会静默失败。
  ///
  /// 实现必须满足协议 §6.5：`echoCancellation + noiseSuppression` 必开
  /// （控制端扬声器正在放被控端的声音，不开会啸叫）；拿不到音轨就返回错误，
  /// 绝不允许「开关亮着但没声音」。
  Future<MicError?> enableMic() async => MicError.unsupported;

  /// 关闭麦克风并 `track.stop()` 释放设备。
  ///
  /// 必须真的 stop：否则系统状态栏的麦克风指示灯会一直亮，用户会以为被偷听。
  Future<void> disableMic() async {}

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