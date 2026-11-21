import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/app_config.dart';

/// `StreamPrefs` 是「画质档 + 分辨率覆盖 + 帧率 + 码率覆盖」合成后的唯一出口，
/// 页面发给 Agent 的 `stream.config` 全部从它取值——所以这里把优先级关系钉死。
void main() {
  const QualityPreset normal = QualityPreset('normal', '高清', '1080P', 1920, 75, 8000);
  const QualityPreset auto = QualityPreset('auto', '自动', '动态', 0, 72, 0);
  const QualityPreset original = QualityPreset('original', '原画', '源分辨率', 0, 90, 60000);

  group('width（分辨率覆盖优先级）', () {
    test('preset：跟随档位自带的宽度', () {
      expect(const StreamPrefs(preset: normal).width, 1920);
    });

    test('原画 / 自动档 width=0 表示不缩放', () {
      expect(const StreamPrefs(preset: original).width, 0);
      expect(const StreamPrefs(preset: auto).width, 0);
    });

    test('follow_remote 覆盖成 0（不缩放），即使档位有宽度', () {
      const StreamPrefs p = StreamPrefs(preset: normal, resolutionKey: 'follow_remote');
      expect(p.width, 0);
    });

    test('follow_local 用控制端算出的像素宽', () {
      const StreamPrefs p = StreamPrefs(
        preset: normal,
        resolutionKey: 'follow_local',
        resolutionWidth: 1440,
      );
      expect(p.width, 1440);
    });

    test('固定分辨率覆盖档位宽度（1080P 档手动选 2K）', () {
      const StreamPrefs p = StreamPrefs(preset: normal, resolutionKey: '2k');
      expect(p.width, 2560);
      expect(p.resolutionLabel, '2K');
    });

    test('自定义分辨率宽度为空时回落到档位', () {
      const StreamPrefs p = StreamPrefs(preset: normal, resolutionKey: 'custom');
      expect(p.width, 1920);
    });
  });

  group('bitrate（三级优先级）', () {
    test('自定义码率优先于档位', () {
      const StreamPrefs p = StreamPrefs(
        preset: normal,
        customBitrate: true,
        bitrateOverride: 15000,
      );
      expect(p.bitrate, 15000);
    });

    test('未开自定义时用档位码率', () {
      const StreamPrefs p = StreamPrefs(preset: normal);
      expect(p.bitrate, 8000);
    });

    test('档位码率为 0（自动档）时按宽度/帧率推算', () {
      const StreamPrefs p = StreamPrefs(preset: auto, fps: 60);
      // 宽度缺失按 1080P 估算：1920*1080*60*0.06/1000 ≈ 7465 kbps
      expect(p.bitrate, closeTo(7465, 5));
    });

    test('autoBitrate 随分辨率和帧率单调递增，并钳在合理区间', () {
      final int small = StreamPrefs.autoBitrate(854, 30);
      final int mid = StreamPrefs.autoBitrate(1920, 60);
      final int big = StreamPrefs.autoBitrate(3840, 60);
      expect(small, lessThan(mid));
      expect(mid, lessThan(big));
      expect(small, greaterThanOrEqualTo(1500));
      expect(StreamPrefs.autoBitrate(3840, 144), lessThanOrEqualTo(50000));
    });
  });

  group('label / copyWith', () {
    test('顶栏文案带档位与帧率', () {
      expect(const StreamPrefs(preset: normal, fps: 60).label, '高清 · 60fps');
      expect(const StreamPrefs(preset: normal, fps: 144).label, '高清 · 144fps');
    });

    test('copyWith 只改指定字段，其余保持', () {
      const StreamPrefs base = StreamPrefs(preset: normal, fps: 60);
      final StreamPrefs next = base.copyWith(fps: 90);
      expect(next.fps, 90);
      expect(next.preset.key, 'normal');
      expect(next.resolutionKey, 'preset');
    });

    test('resolutionLabel 区分「跟随档位 / 跟随被控端 / 固定 / 跟随本机」', () {
      expect(const StreamPrefs(preset: normal).resolutionLabel, '1920P');
      expect(
        const StreamPrefs(preset: normal, resolutionKey: 'follow_remote').resolutionLabel,
        '跟随被控端',
      );
      expect(
        const StreamPrefs(preset: normal, resolutionKey: '4k').resolutionLabel,
        '4K',
      );
      expect(
        const StreamPrefs(
          preset: normal,
          resolutionKey: 'follow_local',
          resolutionWidth: 1600,
        ).resolutionLabel,
        '跟随当前显示屏（1600P）',
      );
    });
  });

  group('ResolutionOption', () {
    test('未知 key 回落到第一项（跟随当前显示屏）', () {
      expect(ResolutionOption.fromKey('nope').key, 'follow_local');
      expect(ResolutionOption.fromKey(null).key, 'follow_local');
    });

    test('固定分辨率项的宽度与标签一致', () {
      expect(ResolutionOption.fromKey('480p').width, 854);
      expect(ResolutionOption.fromKey('4k').width, 3840);
    });
  });
}
