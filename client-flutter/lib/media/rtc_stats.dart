/// WebRTC 统计解析（纯函数，不依赖 flutter_webrtc，可直接单测）。
///
/// 两件事：
/// 1. `getStats()` 的 `inbound-rtp(video)` → HUD 用的 [TransportStats]；
/// 2. 一行固定格式的诊断日志，用来和 Agent 侧「已发 N 帧」对账。
library;

import 'media_transport.dart';

/// 取整数：兼容 num / 数字字符串；缺失或非数字返回 `null`（**不要**当 0 用，
/// 否则「字段不存在」会被误判成「值为 0」）。
int? rtpInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// `inbound-rtp(video)` → HUD 统计。
///
/// fps 有两个来源（协议 §7 只要求「显示 fps」，没规定取哪个）：
/// 1. 原生 `framesPerSecond` —— Chrome/桌面 libwebrtc 一般都有；
/// 2. 没有该字段时，用 `framesDecoded`（或 `framesReceived`）的**增量 / 时间**自算，
///    所以 Android/iOS 上不会出现「画面正常但 HUD 显示 —」。
///
/// 两个都拿不到才返回 `fps == null` → HUD 显示 `—`（表示「还没统计到」，不是 0 帧）。
TransportStats parseInboundStats(
  Map<dynamic, dynamic> values, {
  required int lastFrames,
  required DateTime? lastAt,
  required DateTime now,
}) {
  final int width = rtpInt(values['frameWidth']) ?? 0;
  final int height = rtpInt(values['frameHeight']) ?? 0;
  final int? frames = rtpInt(values['framesDecoded']) ?? rtpInt(values['framesReceived']);

  int? fps = rtpInt(values['framesPerSecond']);
  if (fps == null || fps <= 0) {
    fps = null;
    if (frames != null && frames > 0 && lastAt != null) {
      final double seconds = now.difference(lastAt).inMilliseconds / 1000.0;
      if (seconds > 0.1) {
        final int delta = frames - lastFrames;
        // 计数器回绕/重置时别报负数
        fps = delta <= 0 ? 0 : (delta / seconds).round();
      }
    }
  }
  return TransportStats(fps: fps, width: width, height: height);
}

/// 每秒一行、字段顺序固定的对账日志（方便 `grep '\[webrtc\] rtp'`）：
///
/// ```
/// [webrtc] rtp framesReceived=196 framesDecoded=180 packetsReceived=4210 nack=2 pli=1 jbMs=15
/// ```
///
/// - 全部取自 `inbound-rtp(video)`；字段缺失写 `-`，**绝不抛异常**。
/// - `jbMs` = `jitterBufferDelay / jitterBufferEmittedCount * 1000`（两个都缺失就 `-`）。
/// - `nack` / `pli` 计数只增不减，看增量才有意义（每次会话重新计数）。
String formatRtpStatsLine(Map<dynamic, dynamic> values) {
  final int? delayMicroNs = _jitterDelayMs(values);
  return '[webrtc] rtp'
      ' framesReceived=${_num(values['framesReceived'])}'
      ' framesDecoded=${_num(values['framesDecoded'])}'
      ' packetsReceived=${_num(values['packetsReceived'])}'
      ' nack=${_num(values['nackCount'])}'
      ' pli=${_num(values['pliCount'])}'
      ' jbMs=${delayMicroNs?.toString() ?? '-'}';
}

int? _jitterDelayMs(Map<dynamic, dynamic> values) {
  final num? delay = values['jitterBufferDelay'] is num ? values['jitterBufferDelay'] as num : null;
  final num? emitted =
      values['jitterBufferEmittedCount'] is num ? values['jitterBufferEmittedCount'] as num : null;
  if (delay == null || emitted == null || emitted <= 0) return null;
  return (delay / emitted * 1000).round();
}

String _num(Object? value) => rtpInt(value)?.toString() ?? '-';