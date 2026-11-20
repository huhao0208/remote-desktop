import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/media/media_transport.dart';
import 'package:uu_remote/media/rtc_stats.dart';

void main() {
  group('对账日志 formatRtpStatsLine', () {
    test('字段固定顺序，便于 grep', () {
      final String line = formatRtpStatsLine(<String, dynamic>{
        'framesReceived': 196,
        'framesDecoded': 180,
        'packetsReceived': 4210,
        'nackCount': 2,
        'pliCount': 1,
        'jitterBufferDelay': 0.045, // 秒
        'jitterBufferEmittedCount': 3,
      });
      expect(
        line,
        '[webrtc] rtp framesReceived=196 framesDecoded=180 packetsReceived=4210 '
        'nack=2 pli=1 jbMs=15',
      );
    });

    test('字段缺失写 -，不抛异常、不把缺失当 0', () {
      final String line = formatRtpStatsLine(<String, dynamic>{'framesDecoded': 12});
      expect(line, contains('framesReceived=-'));
      expect(line, contains('framesDecoded=12'));
      expect(line, contains('packetsReceived=-'));
      expect(line, contains('nack=-'));
      expect(line, contains('pli=-'));
      expect(line, contains('jbMs=-'));
    });

    test('空 map / 数字字符串都能处理', () {
      expect(formatRtpStatsLine(<String, dynamic>{}), endsWith('framesReceived=- framesDecoded=- packetsReceived=- nack=- pli=- jbMs=-'));
      expect(
        formatRtpStatsLine(<String, dynamic>{'framesDecoded': '42'}),
        contains('framesDecoded=42'),
      );
    });

    test('跳过统计后仍可解析 rtpInt', () {
      expect(rtpInt(null), isNull);
      expect(rtpInt('7'), 7);
      expect(rtpInt(7.9), 7);
      expect(rtpInt('x'), isNull);
    });
  });

  group('HUD fps 两个来源', () {
    final DateTime now = DateTime(2026, 11, 21, 12, 0, 0);

    test('优先用原生 framesPerSecond', () {
      final TransportStats stats = parseInboundStats(
        <String, dynamic>{'framesPerSecond': 15, 'frameWidth': 1920, 'frameHeight': 1200},
        lastFrames: 0,
        lastAt: null,
        now: now,
      );
      expect(stats.fps, 15);
      expect(stats.width, 1920);
      expect(stats.height, 1200);
      expect(stats.hasVideo, isTrue);
    });

    test('没有 framesPerSecond 时用 framesDecoded 增量自算（Android/iOS 兜底）', () {
      final TransportStats stats = parseInboundStats(
        <String, dynamic>{'framesDecoded': 300, 'frameWidth': 1920, 'frameHeight': 1200},
        lastFrames: 150,
        lastAt: now.subtract(const Duration(seconds: 10)),
        now: now,
      );
      expect(stats.fps, 15);
    });

    test('fps 给 0 但帧数在涨 → 仍按增量算（不显示假的 0）', () {
      final TransportStats stats = parseInboundStats(
        <String, dynamic>{'framesPerSecond': 0, 'framesDecoded': 60},
        lastFrames: 30,
        lastAt: now.subtract(const Duration(seconds: 2)),
        now: now,
      );
      expect(stats.fps, 15);
    });

    test('两个来源都拿不到 → null（HUD 显示 —，不是 0 fps）', () {
      final TransportStats stats = parseInboundStats(
        <String, dynamic>{'frameWidth': 1920, 'frameHeight': 1200},
        lastFrames: 0,
        lastAt: null,
        now: now,
      );
      expect(stats.fps, isNull);
      expect(stats.hasVideo, isTrue);
    });

    test('收到过帧后停住 → 0 fps（真的卡了）', () {
      final TransportStats stats = parseInboundStats(
        <String, dynamic>{'framesDecoded': 300},
        lastFrames: 300,
        lastAt: now.subtract(const Duration(seconds: 1)),
        now: now,
      );
      expect(stats.fps, 0);
    });

    test('计数器回绕/重置不会算出负数', () {
      final TransportStats stats = parseInboundStats(
        <String, dynamic>{'framesDecoded': 5},
        lastFrames: 900,
        lastAt: now.subtract(const Duration(seconds: 1)),
        now: now,
      );
      expect(stats.fps, 0);
    });
  });
}