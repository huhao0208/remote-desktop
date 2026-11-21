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
        if (delta < 0) {
          // 计数器回退 = 换了 SSRC / 轨被替换：这一拍算不出 fps，给 null（HUD 显示 —），
          // 不要报成 0 ——「0 fps」的语义是「到过帧又停了」，和重置不是一回事。
          fps = null;
        } else {
          // delta == 0 才是真的卡住，如实报 0
          fps = (delta / seconds).round();
        }
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

// ---------------------------------------------------------------------------
// 连接信息面板（docs/远控复刻基线.md P0-2）
// ---------------------------------------------------------------------------

/// 一份「面板用」的快照：把整份 `getStats()` 里散落在
/// `inbound-rtp` / `candidate-pair` / `local-candidate` / `codec` 四类对象
/// 上的字段合成一个结构。
///
/// 为什么不在 [TransportStats] 里直接解析：面板要的是「这一秒这一条链路」，
/// 需要跨对象 join（候选对 ↔ 本地候选 ↔ 编解码器），而 HUD 只要 fps/分辨率。
/// 两者混在一起会让 HUD 的单测依赖整份报告。
class StatsSnapshot {
  const StatsSnapshot({
    this.fps,
    this.width = 0,
    this.height = 0,
    this.framesDecoded,
    this.framesDropped,
    this.jitterMs,
    this.jitterBufferMs,
    this.lossPercent,
    this.kbps,
    this.rttMs,
    this.codec,
    this.iceType,
  });

  final int? fps;
  final int width;
  final int height;
  final int? framesDecoded;
  final int? framesDropped;
  final int? jitterMs;
  final int? jitterBufferMs;

  /// 0–100；没有 `packetsReceived` 时为 `null`（不是 0）。
  final double? lossPercent;

  /// 接收码率 kbps（按 `bytesReceived` 增量折算）；首拍没有基线时为 `null`。
  final int? kbps;
  final int? rttMs;

  /// `H.264` / `VP8` …；`video/H264` 这类 mime 会规整成短名。
  final String? codec;

  /// `host` / `srflx` / `prflx` / `relay`。
  final String? iceType;

  TransportStats toTransportStats() => TransportStats(
        fps: fps,
        width: width,
        height: height,
        rttMs: rttMs,
        bitrateKbps: kbps,
        lossPercent: lossPercent,
        jitterMs: jitterMs,
        jitterBufferMs: jitterBufferMs,
        dropped: framesDropped,
        codec: codec,
        iceType: iceType,
      );
}

/// `getStats()` 报告 → [StatsSnapshot]。
///
/// [reports] 每项形如 `{"id": "...", "type": "inbound-rtp", "kind": "video", ...}`，
/// 即把 `StatsReport.id/type/values` 摊平后的 Map。纯函数，可直接单测。
///
/// 所有字段**缺就返回 null**，绝不用 0 冒充——面板上「—」表示拿不到，
/// 「0 ms」表示真的测得 0，两者排障含义完全不同。
StatsSnapshot parseStatsSnapshot(
  List<Map<String, dynamic>> reports, {
  int lastFrames = 0,
  int lastBytes = 0,
  DateTime? lastAt,
  DateTime? now,
}) {
  Map<String, dynamic>? inbound;
  Map<String, dynamic>? transport;
  final Map<String, Map<String, dynamic>> pairs = <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> candidates = <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> codecs = <String, Map<String, dynamic>>{};

  for (final Map<String, dynamic> r in reports) {
    final String type = (r['type'] ?? '').toString();
    final String id = (r['id'] ?? '').toString();
    switch (type) {
      case 'inbound-rtp':
        final String kind = (r['kind'] ?? r['mediaType'] ?? '').toString();
        if (kind == 'video' && inbound == null) inbound = r;
      case 'transport':
        transport ??= r;
      case 'candidate-pair':
        pairs[id] = r;
      case 'local-candidate':
      case 'remote-candidate':
        candidates[id] = r;
      case 'codec':
        codecs[id] = r;
    }
  }

  if (inbound == null) return const StatsSnapshot();

  final int width = rtpInt(inbound['frameWidth']) ?? 0;
  final int height = rtpInt(inbound['frameHeight']) ?? 0;
  final int? frames = rtpInt(inbound['framesDecoded']) ?? rtpInt(inbound['framesReceived']);

  int? fps = rtpInt(inbound['framesPerSecond']);
  if (fps == null || fps <= 0) {
    fps = null;
    if (frames != null && frames > 0 && lastAt != null && now != null) {
      final double seconds = now.difference(lastAt).inMilliseconds / 1000.0;
      if (seconds > 0.1) {
        final int delta = frames - lastFrames;
        if (delta >= 0) fps = (delta / seconds).round();
      }
    }
  }

  // 丢包率：packetsLost 可能是负数（重复包），钳到 0
  final int? received = rtpInt(inbound['packetsReceived']);
  final int? lost = rtpInt(inbound['packetsLost']);
  double? lossPercent;
  if (received != null && lost != null) {
    final int total = received + (lost > 0 ? lost : 0);
    if (total > 0) lossPercent = (lost > 0 ? lost : 0) * 100.0 / total;
  }

  // 抖动：inbound-rtp.jitter 单位是秒
  final num? jitterSec = inbound['jitter'] is num ? inbound['jitter'] as num : null;
  final int? jitterMs = jitterSec == null ? null : (jitterSec * 1000).round();

  // 抖动缓冲深度
  int? jitterBufferMs;
  final num? jbDelay =
      inbound['jitterBufferDelay'] is num ? inbound['jitterBufferDelay'] as num : null;
  final num? jbEmitted =
      inbound['jitterBufferEmittedCount'] is num ? inbound['jitterBufferEmittedCount'] as num : null;
  if (jbDelay != null && jbEmitted != null && jbEmitted > 0) {
    jitterBufferMs = (jbDelay / jbEmitted * 1000).round();
  }

  // 码率：字节增量 / 秒
  int? kbps;
  final int? bytes = rtpInt(inbound['bytesReceived']);
  if (bytes != null && lastAt != null && now != null && lastBytes > 0) {
    final double seconds = now.difference(lastAt).inMilliseconds / 1000.0;
    final int delta = bytes - lastBytes;
    if (seconds > 0.1 && delta >= 0) kbps = (delta * 8 / seconds / 1000).round();
  }

  // 编码格式
  String? codec;
  final String codecId = (inbound['codecId'] ?? '').toString();
  final Map<String, dynamic>? codecReport = codecs[codecId];
  final String mime =
      (codecReport?['mimeType'] ?? codecReport?['codec'] ?? '').toString();
  if (mime.isNotEmpty) {
    final String short = mime.split('/').last.toUpperCase();
    codec = short == 'H264' ? 'H.264' : (short == 'H265' ? 'H.265' : short);
  }

  // 选中的候选对 → 对端候选类型 → iceType
  String? iceType;
  String? pairId = (transport?['selectedCandidatePairId'] ?? '').toString();
  if (pairId.isEmpty) {
    // 部分实现不给 transport.selectedCandidatePairId，退回「nominated / succeeded」
    for (final MapEntry<String, Map<String, dynamic>> e in pairs.entries) {
      final bool nominated = e.value['nominated'] == true;
      final String state = (e.value['state'] ?? '').toString();
      if (nominated || state == 'succeeded') {
        pairId = e.key;
        break;
      }
    }
  }
  final Map<String, dynamic>? pair = pairs[pairId];
  if (pair != null) {
    final String remoteId = (pair['remoteCandidateId'] ?? '').toString();
    final String localId = (pair['localCandidateId'] ?? '').toString();
    final Map<String, dynamic>? remote = candidates[remoteId];
    final Map<String, dynamic>? local = candidates[localId];
    final String type =
        (remote?['candidateType'] ?? local?['candidateType'] ?? '').toString();
    if (type.isNotEmpty) iceType = type;
  }

  // RTT：currentRoundTripTime 单位是秒
  int? rttMs;
  final num? rttSec =
      pair?['currentRoundTripTime'] is num ? pair!['currentRoundTripTime'] as num : null;
  if (rttSec != null) rttMs = (rttSec * 1000).round();

  return StatsSnapshot(
    fps: fps,
    width: width,
    height: height,
    framesDecoded: frames,
    framesDropped: rtpInt(inbound['framesDropped']),
    jitterMs: jitterMs,
    jitterBufferMs: jitterBufferMs,
    lossPercent: lossPercent,
    kbps: kbps,
    rttMs: rttMs,
    codec: codec,
    iceType: iceType,
  );
}