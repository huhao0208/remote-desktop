import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/models.dart';
import '../core/theme.dart';
import '../media/media_transport.dart';
import 'ui_kit.dart';

/// 连接信息面板的数据快照（对齐官方 `Control.Connection` 的 28 个字段）。
///
/// 设计原则：**能拿到就给值，拿不到就 `null`**。面板上「—」= 该项平台/版本
/// 不提供，和「0」语义不同；复制出来的文本同样保留「—」，方便客服对表。
class RemoteInfoData {
  const RemoteInfoData({
    required this.deviceName,
    this.connectedAt,
    this.latencyMs,
    this.latencyAvgMs,
    this.latencyMaxMs,
    this.lossPercent,
    this.bitrateKbps,
    this.fps,
    this.frameLatencyMs,
    this.width = 0,
    this.height = 0,
    this.qualityLabel,
    this.capture,
    this.codec,
    this.encoderDecoder,
    this.iceType,
    this.encrypted = true,
    this.clientSystem,
    this.clientVersion,
    this.clientIp,
    this.agentSystem,
    this.agentVersion,
    this.agentIp,
    this.screenLabel,
    this.transportLabel,
    this.audioLabel,
  });

  final String deviceName;
  final DateTime? connectedAt;
  final int? latencyMs;
  final int? latencyAvgMs;
  final int? latencyMaxMs;
  final double? lossPercent;
  final int? bitrateKbps;
  final int? fps;
  final int? frameLatencyMs;
  final int width;
  final int height;
  final String? qualityLabel;
  final String? capture;
  final String? codec;
  final String? encoderDecoder;

  /// `host` / `srflx` / `relay` …（见 [TransportStats.iceType]）
  final String? iceType;
  final bool encrypted;
  final String? clientSystem;
  final String? clientVersion;
  final String? clientIp;
  final String? agentSystem;
  final String? agentVersion;
  final String? agentIp;
  final String? screenLabel;
  final String? transportLabel;
  final String? audioLabel;

  static String _dash(Object? v) {
    if (v == null) return '—';
    final String s = '$v'.trim();
    return s.isEmpty ? '—' : s;
  }

  String get connectionTime {
    final DateTime? at = connectedAt;
    if (at == null) return '—';
    final Duration d = DateTime.now().difference(at);
    final String hh = d.inHours.toString().padLeft(2, '0');
    final String mm = (d.inMinutes % 60).toString().padLeft(2, '0');
    final String ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  String get resolutionLabel => (width > 0 && height > 0) ? '$width × $height' : '—';

  /// 「复制全部信息」的纯文本（官方同款排障入口）。
  String toText() {
    final String ice = iceType ?? '';
    final String path = ice.isEmpty ? '—' : (const <String, String>{
      'host': '局域网直连',
      'srflx': 'P2P 直连（NAT 穿透）',
      'prflx': 'P2P 直连（对称 NAT）',
      'relay': '安全中转连接',
    }[ice] ?? ice);
    return <String>[
      '远程连接信息',
      '====================',
      '连接时间: $connectionTime',
      '',
      '[网络]',
      '网络延时: 当前 ${_dash(latencyMs == null ? null : '${latencyMs}ms')} / '
          '平均 ${_dash(latencyAvgMs == null ? null : '${latencyAvgMs}ms')} / '
          '最高 ${_dash(latencyMaxMs == null ? null : '${latencyMaxMs}ms')}',
      '丢包率: ${lossPercent == null ? '—' : '${lossPercent!.toStringAsFixed(1)}%'}',
      '带宽占用: ${bitrateKbps == null ? '—' : '${(bitrateKbps! / 1000).toStringAsFixed(1)} Mbps'}',
      '连接方式: $path',
      '',
      '[画面]',
      '帧率: ${fps == null ? '—' : '$fps fps'}',
      '帧延时: ${frameLatencyMs == null ? '—' : '${frameLatencyMs}ms'}',
      '分辨率: $resolutionLabel',
      '画质: ${_dash(qualityLabel)}',
      '采集方式: ${_dash(capture)}',
      '编码模式: ${_dash(codec)}',
      '编解码器: ${_dash(encoderDecoder)}',
      '媒体通路: ${_dash(transportLabel)}',
      '音频: ${_dash(audioLabel)}',
      '',
      '[安全]',
      '加密通道: ${encrypted ? '✓（SRTP/DTLS）' : '—'}',
      '',
      '[控制端]',
      '系统: ${_dash(clientSystem)}',
      '版本: ${_dash(clientVersion)}',
      'IP: ${_dash(clientIp)}',
      '',
      '[被控端]',
      '设备: $deviceName',
      '系统: ${_dash(agentSystem)}',
      '版本: ${_dash(agentVersion)}',
      'IP: ${_dash(agentIp)}',
      '显示屏: ${_dash(screenLabel)}',
    ].join('\n');
  }
}

/// 打开展示面板（桌面用 Dialog，移动端自动变成可滚动的居中卡片）。
Future<void> showRemoteInfoDialog(BuildContext context, RemoteInfoData data) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (BuildContext ctx) => _RemoteInfoDialog(data: data),
  );
}

class _RemoteInfoDialog extends StatefulWidget {
  const _RemoteInfoDialog({required this.data});

  final RemoteInfoData data;

  @override
  State<_RemoteInfoDialog> createState() => _RemoteInfoDialogState();
}

class _RemoteInfoDialogState extends State<_RemoteInfoDialog> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.data.toText()));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final RemoteInfoData d = widget.data;
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.sm, AppSpace.sm),
              child: Row(
                children: <Widget>[
                  const Text('远程连接信息',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _copy,
                    icon: Icon(_copied ? Icons.check : Icons.copy_all_outlined, size: 16),
                    label: Text(_copied ? '已复制' : '复制全部信息'),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.lg, vertical: AppSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _row('连接时间', d.connectionTime),
                    _group('网络'),
                    _row('网络延时',
                        '当前 ${_ms(d.latencyMs)} · 平均 ${_ms(d.latencyAvgMs)} · 最高 ${_ms(d.latencyMaxMs)}'),
                    _row('丢包率',
                        d.lossPercent == null ? '—' : '${d.lossPercent!.toStringAsFixed(1)}%'),
                    _row('带宽占用',
                        d.bitrateKbps == null
                            ? '—'
                            : '${(d.bitrateKbps! / 1000).toStringAsFixed(1)} Mbps'),
                    _row('连接方式', _pathLabel(d.iceType)),
                    _group('画面'),
                    _row('帧率', d.fps == null ? '—' : '${d.fps} fps'),
                    _row('帧延时', _ms(d.frameLatencyMs)),
                    _row('分辨率', d.resolutionLabel),
                    _row('画质', d.qualityLabel ?? '—'),
                    _row('采集方式', d.capture ?? '—'),
                    _row('编码模式', d.codec ?? '—'),
                    _row('编解码器', d.encoderDecoder ?? '—'),
                    _row('媒体通路', d.transportLabel ?? '—'),
                    _row('音频', d.audioLabel ?? '—'),
                    _group('安全'),
                    _row('加密通道', d.encrypted ? '已加密（SRTP/DTLS）' : '—'),
                    _group('控制端'),
                    _row('系统', d.clientSystem ?? '—'),
                    _row('版本', d.clientVersion ?? '—'),
                    _row('IP', d.clientIp ?? '—'),
                    _group('被控端'),
                    _row('设备', d.deviceName),
                    _row('系统', d.agentSystem ?? '—'),
                    _row('版本', d.agentVersion ?? '—'),
                    _row('IP', d.agentIp ?? '—'),
                    _row('显示屏', d.screenLabel ?? '—'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _ms(int? v) => v == null ? '—' : '${v}ms';

  static String _pathLabel(String? ice) {
    switch (ice) {
      case 'host':
        return '局域网直连';
      case 'srflx':
        return 'P2P 直连（NAT 穿透）';
      case 'prflx':
        return 'P2P 直连（对称 NAT）';
      case 'relay':
        return '安全中转连接';
      default:
        return '—';
    }
  }

  Widget _group(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.md, bottom: AppSpace.xs),
      child: SectionLabel(text: title),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 78,
            child: Text(label, style: const TextStyle(fontSize: 12.5, color: AppColors.muted)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 12.5, color: AppColors.text, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// 从页面状态拼出面板数据，避免把「怎么取字段」散在 UI 里。
RemoteInfoData buildRemoteInfoData({
  required String deviceName,
  required DeviceInfo device,
  required AgentHello? hello,
  required TransportStats stats,
  required String? transportKind,
  required DateTime? connectedAt,
  required int screenIndex,
  required int screenCount,
  required bool audioAvailable,
  required bool audioMuted,
  required String qualityLabel,
  required String clientVersion,
  required List<int> latencyHistory,
}) {
  int? avg;
  int? max;
  if (latencyHistory.isNotEmpty) {
    final int sum = latencyHistory.reduce((int a, int b) => a + b);
    avg = (sum / latencyHistory.length).round();
    max = latencyHistory.reduce((int a, int b) => a > b ? a : b);
  }
  final int? current = latencyHistory.isEmpty ? null : latencyHistory.last;
  final int? rtt = stats.rttMs ?? current;

  return RemoteInfoData(
    deviceName: hello?.name ?? device.name,
    connectedAt: connectedAt,
    latencyMs: rtt,
    latencyAvgMs: avg ?? rtt,
    latencyMaxMs: max ?? rtt,
    lossPercent: stats.lossPercent,
    bitrateKbps: stats.bitrateKbps,
    fps: stats.fps,
    frameLatencyMs: rtt == null
        ? null
        : (rtt / 2 + (stats.jitterBufferMs ?? 0)).round(),
    width: stats.width > 0 ? stats.width : (hello?.width ?? 0),
    height: stats.height > 0 ? stats.height : (hello?.height ?? 0),
    qualityLabel: qualityLabel,
    capture: hello?.capture ?? (transportKind == 'jpeg' ? '屏幕轮询（JPG）' : '屏幕采集'),
    codec: stats.codec ?? (transportKind == 'jpeg' ? 'JPEG' : 'H.264'),
    encoderDecoder: transportKind == 'jpeg' ? '软编 / 软解' : '硬编优先 / 硬解优先',
    iceType: stats.iceType,
    clientSystem: _clientSystem(),
    clientVersion: clientVersion,
    clientIp: null,
    agentSystem: hello?.os,
    agentVersion: hello?.version,
    agentIp: hello?.ip,
    screenLabel: screenCount > 0 ? '${screenIndex + 1} / $screenCount' : null,
    transportLabel: hello?.media == 'webrtc' ? 'WebRTC（H.264 + SRTP/UDP）' : 'WS 兜底（JPG）',
    audioLabel: !audioAvailable
        ? '未启用'
        : (audioMuted ? '已静音（本地）' : '有声'),
  );
}

String _clientSystem() {
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isWindows) return 'Windows';
  if (Platform.isLinux) return 'Linux';
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  return Platform.operatingSystem;
}
