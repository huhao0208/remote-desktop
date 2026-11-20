import 'package:flutter/widgets.dart' show BoxFit;
import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/app_config.dart';
import 'package:uu_remote/media/media_transport.dart';
import 'package:uu_remote/media/webrtc_transport.dart';

void main() {
  group('TransportStats（HUD 口径）', () {
    test('默认 fps 为 null：还没收到首帧 ≠ 0 fps 卡住', () {
      const TransportStats stats = TransportStats();
      expect(stats.fps, isNull);
      expect(stats.hasVideo, isFalse);
    });

    test('收到过帧后的 0 fps 是有意义的值（真的卡了）', () {
      const TransportStats stats = TransportStats(fps: 0, width: 1920, height: 1080);
      expect(stats.fps, 0);
      expect(stats.hasVideo, isTrue);
    });
  });

  group('WebRtcTransport 初始态', () {
    test('未 start 时统计为 null-fps，画面给占位视图而不是抛错', () {
      final WebRtcTransport transport = WebRtcTransport();
      expect(transport.kind, 'webrtc');
      expect(transport.stats.value.fps, isNull);
      expect(transport.fallbackReason, isNull);
      expect(transport.buildView(fit: BoxFit.contain), isNotNull);
      addTearDown(transport.dispose);
    });
  });

  group('AppConfig.defaultServer', () {
    test('没有 --dart-define=UU_SERVER 时用内置自托管地址', () {
      // 单测不带 dart-define，走常量分支
      expect(AppConfig.defaultServer, startsWith('http'));
      expect(Uri.tryParse(AppConfig.defaultServer)?.host, isNotEmpty);
    });

    test('画质档位不受服务端覆盖影响', () {
      expect(AppConfig.qualityPresets.map((QualityPreset p) => p.value).first, '1280,55,4000');
    });

    test('--dart-define=UU_SERVER 时优先于内置常量', () {
      const String env = String.fromEnvironment('UU_SERVER');
      if (env.isEmpty) {
        expect(AppConfig.defaultServer, contains('sslip.io'));
      } else {
        expect(AppConfig.defaultServer, env);
      }
    });
  });
}