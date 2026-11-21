import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/models.dart';
import 'package:uu_remote/media/media_transport.dart';
import 'package:uu_remote/media/rtc_stats.dart';
import 'package:uu_remote/widgets/remote_info_panel.dart';

/// 一份贴近真实 `getStats()` 的报告（字段名按 WebRTC 规范。
/// 值刻意取整数，方便手算校验，不用浮点近似）。
List<Map<String, dynamic>> _fullReport() => <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'IT01',
        'type': 'inbound-rtp',
        'kind': 'video',
        'frameWidth': 1920,
        'frameHeight': 1080,
        'framesPerSecond': 60,
        'framesDecoded': 600,
        'framesDropped': 3,
        'packetsReceived': 1000,
        'packetsLost': 10,
        'jitter': 0.012,
        'jitterBufferDelay': 2.5,
        'jitterBufferEmittedCount': 100,
        'bytesReceived': 1250000,
        'codecId': 'COT01',
      },
      <String, dynamic>{'id': 'COT01', 'type': 'codec', 'mimeType': 'video/H264'},
      <String, dynamic>{
        'id': 'T01',
        'type': 'transport',
        'selectedCandidatePairId': 'CP01',
      },
      <String, dynamic>{
        'id': 'CP01',
        'type': 'candidate-pair',
        'localCandidateId': 'L01',
        'remoteCandidateId': 'R01',
        'currentRoundTripTime': 0.018,
      },
      <String, dynamic>{'id': 'R01', 'type': 'remote-candidate', 'candidateType': 'relay'},
    ];

void main() {
  group('parseStatsSnapshot（连接信息面板口径）', () {
    test('完整报告：分辨率/fps/丢包/抖动/码率/RTT/编码/链路全解析', () {
      final DateTime now = DateTime(2026, 11, 21, 12, 0, 0);
      final StatsSnapshot s = parseStatsSnapshot(
        _fullReport(),
        lastBytes: 1000000,
        lastFrames: 540,
        lastAt: now.subtract(const Duration(seconds: 1)),
        now: now,
      );

      expect(s.fps, 60);
      expect(s.width, 1920);
      expect(s.height, 1080);
      expect(s.framesDropped, 3);
      expect(s.rttMs, 18); // 0.018s
      expect(s.jitterMs, 12); // 0.012s
      expect(s.jitterBufferMs, 25); // 2.5/100 * 1000
      expect(s.codec, 'H.264');
      expect(s.iceType, 'relay');
      // 10 / (1000 + 10) * 100
      expect(s.lossPercent, closeTo(0.990, 0.001));
      // (1250000-1000000) * 8 / 1s / 1000
      expect(s.kbps, 2000);

      final TransportStats t = s.toTransportStats();
      expect(t.connectionPathLabel, '安全中转连接');
      expect(t.hasVideo, isTrue);
    });

    test('缺字段一律 null，不用 0 冒充（面板要区分「—」和「0 ms」）', () {
      final DateTime now = DateTime(2026, 11, 21, 12, 0, 0);
      final StatsSnapshot s = parseStatsSnapshot(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'IT01',
            'type': 'inbound-rtp',
            'kind': 'video',
            'frameWidth': 1280,
            'frameHeight': 720,
          },
        ],
        lastAt: now.subtract(const Duration(seconds: 1)),
        now: now,
      );
      expect(s.width, 1280);
      expect(s.rttMs, isNull);
      expect(s.lossPercent, isNull);
      expect(s.kbps, isNull);
      expect(s.codec, isNull);
      expect(s.iceType, isNull);
      expect(s.jitterMs, isNull);
      expect(s.jitterBufferMs, isNull);
      expect(s.framesDropped, isNull);
      expect(s.toTransportStats().connectionPathLabel, '—');
    });

    test('没有 inbound-rtp 时返回空快照，不抛异常', () {
      final StatsSnapshot s = parseStatsSnapshot(<Map<String, dynamic>>[
        <String, dynamic>{'id': 'T01', 'type': 'transport'},
      ]);
      expect(s.fps, isNull);
      expect(s.width, 0);
      expect(s.hasVideoOrNothing(), isTrue);
    });

    test('packetsLost 为负（重复包）时按 0 处理，不出负丢包率', () {
      final StatsSnapshot s = parseStatsSnapshot(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'IT01',
          'type': 'inbound-rtp',
          'kind': 'video',
          'packetsReceived': 500,
          'packetsLost': -8,
        },
      ]);
      expect(s.lossPercent, 0);
    });

    test('候选对没有 selectedCandidatePairId 时退回 nominated', () {
      final StatsSnapshot s = parseStatsSnapshot(<Map<String, dynamic>>[
        <String, dynamic>{'id': 'IT01', 'type': 'inbound-rtp', 'kind': 'video'},
        <String, dynamic>{'id': 'CP01', 'type': 'candidate-pair', 'nominated': true, 'remoteCandidateId': 'R01'},
        <String, dynamic>{'id': 'R01', 'type': 'remote-candidate', 'candidateType': 'host'},
      ]);
      expect(s.iceType, 'host');
    });
  });

  group('RemoteInfoData（复制全部信息）', () {
    test('全空时每项都是「—」，不出现 null 字样', () {
      const RemoteInfoData d = RemoteInfoData(deviceName: 'MY-PC');
      final String text = d.toText();
      expect(text, contains('远程连接信息'));
      expect(text, contains('[网络]'));
      expect(text, contains('[画面]'));
      expect(text, contains('[控制端]'));
      expect(text, contains('[被控端]'));
      expect(text, isNot(contains('null')));
      expect(text, contains('网络延时: 当前 — / 平均 — / 最高 —'));
      expect(text, contains('分辨率: —'));
    });

    test('有值时按官方格式输出（ms / Mbps / fps）', () {
      final RemoteInfoData d = RemoteInfoData(
        deviceName: 'DESK',
        latencyMs: 18,
        latencyAvgMs: 22,
        latencyMaxMs: 87,
        lossPercent: 0.3,
        bitrateKbps: 12400,
        fps: 60,
        width: 2560,
        height: 1440,
        qualityLabel: '超清',
        codec: 'H.264',
        iceType: 'host',
        agentVersion: '0.2.0',
        agentIp: '192.168.1.20',
        screenLabel: '1 / 2',
      );
      final String text = d.toText();
      expect(text, contains('网络延时: 当前 18ms / 平均 22ms / 最高 87ms'));
      expect(text, contains('丢包率: 0.3%'));
      expect(text, contains('带宽占用: 12.4 Mbps'));
      expect(text, contains('连接方式: 局域网直连'));
      expect(text, contains('帧率: 60 fps'));
      expect(text, contains('分辨率: 2560 × 1440'));
      expect(text, contains('版本: 0.2.0'));
      expect(text, contains('IP: 192.168.1.20'));
      expect(text, contains('显示屏: 1 / 2'));
    });

    test('连接时长格式 hh:mm:ss（未连上时为「—」）', () {
      const RemoteInfoData none = RemoteInfoData(deviceName: 'X');
      expect(none.connectionTime, '—');
      final RemoteInfoData d = RemoteInfoData(
        deviceName: 'X',
        connectedAt: DateTime.now().subtract(const Duration(hours: 1, minutes: 2, seconds: 3)),
      );
      expect(d.connectionTime, matches(RegExp(r'^0[01]:0[12]:0[23]$')));
    });
  });

  group('ScreenInfo（协议 v2 §3）', () {
    test('解析列表并按 id 保序，主屏加标注', () {
      final List<ScreenInfo> list = ScreenInfo.listFrom(<Object?>[
        <String, dynamic>{'id': 0, 'w': 2048, 'h': 1280, 'name': '内建', 'primary': true},
        <String, dynamic>{'id': 1, 'w': 1920, 'h': 1080, 'name': '外接'},
      ]);
      expect(list.length, 2);
      expect(list[0].label, '内建 · 2048×1280（主）');
      expect(list[1].label, '外接 · 1920×1080');
      expect(list[1].primary, isFalse);
    });

    test('脏数据（非 List / 非 Map 元素）不抛异常，只丢弃', () {
      expect(ScreenInfo.listFrom(null), isEmpty);
      expect(ScreenInfo.listFrom('x'), isEmpty);
      expect(ScreenInfo.listFrom(<Object?>[1, 'a']), isEmpty);
    });
  });

  group('AgentHello 扩展字段（向后兼容）', () {
    test('老 Agent 无 version/ip/capture 时为 null，screens 默认 1', () {
      final AgentHello h = AgentHello.fromJson(<String, dynamic>{
        'name': 'OLD',
        'os': 'Darwin',
        'screen': <String, dynamic>{'w': 1920, 'h': 1080},
        'media': 'webrtc',
      });
      expect(h.version, isNull);
      expect(h.ip, isNull);
      expect(h.capture, isNull);
      expect(h.screens, 1);
    });

    test('新 Agent 的 version/ip/capture 全带上', () {
      final AgentHello h = AgentHello.fromJson(<String, dynamic>{
        'name': 'NEW',
        'os': 'Darwin',
        'screen': <String, dynamic>{'w': 2560, 'h': 1440},
        'media': 'webrtc',
        'screens': 2,
        'version': '0.2.1',
        'ip': '192.168.1.20',
        'capture': 'mss',
      });
      expect(h.version, '0.2.1');
      expect(h.ip, '192.168.1.20');
      expect(h.capture, 'mss');
      expect(h.screens, 2);
    });
  });
}

/// 测试辅助：空快照不应该有画面尺寸。
extension on StatsSnapshot {
  bool hasVideoOrNothing() => width == 0 && height == 0;
}
