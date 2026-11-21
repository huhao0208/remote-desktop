import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/mini_window.dart';

/// 宽高比（测试里到处要算，单拎出来避免手滑）。
double _ratio(Size size) => size.width / size.height;

/// 小窗模式的状态与几何：这里每个数字都对应屏幕上「窗口在哪、多大、有多透」，
/// 一旦算错就是窗口跑到屏幕外找不回来，所以边界值全部钉死。
void main() {
  group('MiniWindowState 默认值与 copyWith', () {
    test('默认值：未开启、置顶、0.95 透明度、标准档、可拖动', () {
      const MiniWindowState state = MiniWindowState();
      expect(state.enabled, isFalse);
      expect(state.alwaysOnTop, isTrue);
      expect(state.opacity, 0.95);
      expect(state.size, MiniWindowSize.normal);
      expect(state.movable, isTrue);
    });

    test('copyWith 逐字段替换，未传的字段保持不变', () {
      const MiniWindowState state = MiniWindowState();
      final MiniWindowState next = state.copyWith(
        enabled: true,
        alwaysOnTop: false,
        opacity: 0.5,
        size: MiniWindowSize.large,
        movable: false,
      );
      expect(next.enabled, isTrue);
      expect(next.alwaysOnTop, isFalse);
      expect(next.opacity, 0.5);
      expect(next.size, MiniWindowSize.large);
      expect(next.movable, isFalse);
      // 旧对象不被就地修改
      expect(state.enabled, isFalse);
      expect(state.opacity, 0.95);
    });

    test('copyWith 只改一个字段时其余沿用旧值', () {
      const MiniWindowState state = MiniWindowState(size: MiniWindowSize.compact);
      final MiniWindowState next = state.copyWith(enabled: true);
      expect(next.enabled, isTrue);
      expect(next.size, MiniWindowSize.compact);
      expect(next.alwaysOnTop, isTrue);
      expect(next.opacity, 0.95);
      expect(next.movable, isTrue);
    });

    test('opacity 下限夹取：0.1 与 0 都变成 0.3', () {
      const MiniWindowState state = MiniWindowState();
      expect(state.copyWith(opacity: 0.1).opacity, MiniWindowLayout.minOpacity);
      expect(state.copyWith(opacity: 0).opacity, MiniWindowLayout.minOpacity);
    });

    test('opacity 上限夹取：2.0 与 1.5 都变成 1.0', () {
      const MiniWindowState state = MiniWindowState();
      expect(state.copyWith(opacity: 2.0).opacity, MiniWindowLayout.maxOpacity);
      expect(state.copyWith(opacity: 1.5).opacity, MiniWindowLayout.maxOpacity);
    });

    test('opacity 为 NaN 时用下限 0.3，避免整条渲染链失效', () {
      const MiniWindowState state = MiniWindowState();
      expect(state.copyWith(opacity: double.nan).opacity, MiniWindowLayout.minOpacity);
      // 连旧值本身就是 NaN 时也要被救回来
      final MiniWindowState broken = const MiniWindowState(opacity: double.nan).copyWith();
      expect(broken.opacity, MiniWindowLayout.minOpacity);
    });

    test('区间内的透明度原样保留', () {
      const MiniWindowState state = MiniWindowState();
      expect(state.copyWith(opacity: 0.3).opacity, 0.3);
      expect(state.copyWith(opacity: 0.7).opacity, 0.7);
      expect(state.copyWith(opacity: 1.0).opacity, 1.0);
    });
  });

  group('MiniWindowSize 文案与系数', () {
    test('三档中文名分别为 紧凑 / 标准 / 大', () {
      expect(MiniWindowSize.compact.label, '紧凑');
      expect(MiniWindowSize.normal.label, '标准');
      expect(MiniWindowSize.large.label, '大');
    });

    test('系数依次为 0.34 / 0.5 / 0.68', () {
      expect(MiniWindowSize.compact.factor, 0.34);
      expect(MiniWindowSize.normal.factor, 0.5);
      expect(MiniWindowSize.large.factor, 0.68);
    });
  });

  group('windowSize 尺寸计算', () {
    const Size screen = Size(1920, 1080);
    const Size desktop = Size(1920, 1080);

    test('16:9 屏 + 16:9 被控端：标准档为 960×540（屏幕 1/2 × 1/2）', () {
      final Size size = MiniWindowLayout.windowSize(screen: screen, desktopResolution: desktop);
      expect(size, const Size(960, 540));
    });

    test('紧凑档与大档按系数缩放，且都是整数像素', () {
      final Size compact = MiniWindowLayout.windowSize(
        screen: screen,
        desktopResolution: desktop,
        size: MiniWindowSize.compact,
      );
      final Size large = MiniWindowLayout.windowSize(
        screen: screen,
        desktopResolution: desktop,
        size: MiniWindowSize.large,
      );
      expect(compact, const Size(652, 367));
      expect(large, const Size(1305, 734));
      // 取整后仍然是整数
      expect(compact.width, compact.width.floorToDouble());
      expect(large.height, large.height.floorToDouble());
    });

    test('三档的宽高比都与被控端一致（16:9 被控端）', () {
      for (final MiniWindowSize preset in MiniWindowSize.values) {
        final Size size = MiniWindowLayout.windowSize(
          screen: screen,
          desktopResolution: desktop,
          size: preset,
        );
        expect(_ratio(size), closeTo(16 / 9, 0.01), reason: '${preset.label} 档被拉变形了');
      }
    });

    test('三档的宽高比都与被控端一致（16:10 被控端）', () {
      for (final MiniWindowSize preset in MiniWindowSize.values) {
        final Size size = MiniWindowLayout.windowSize(
          screen: screen,
          desktopResolution: const Size(1920, 1200),
          size: preset,
        );
        expect(_ratio(size), closeTo(1.6, 0.01), reason: '${preset.label} 档被拉变形了');
      }
    });

    test('大档也不超过可用区的 75%', () {
      for (final MiniWindowSize preset in MiniWindowSize.values) {
        final Size size = MiniWindowLayout.windowSize(
          screen: screen,
          desktopResolution: desktop,
          size: preset,
        );
        expect(size.width, lessThanOrEqualTo(screen.width * MiniWindowLayout.maxRatio));
        expect(size.height, lessThanOrEqualTo(screen.height * MiniWindowLayout.maxRatio));
      }
    });

    test('竖屏被控端：按高度上限 75% 收缩，比例仍是被控端的', () {
      final Size size = MiniWindowLayout.windowSize(
        screen: screen,
        desktopResolution: const Size(1080, 1920),
        size: MiniWindowSize.large,
      );
      expect(size.height, lessThanOrEqualTo(1080 * MiniWindowLayout.maxRatio));
      expect(size.width, lessThanOrEqualTo(1920 * MiniWindowLayout.maxRatio));
      expect(_ratio(size), closeTo(1080 / 1920, 0.01));
    });

    test('desktopResolution 为 0（还没收到 hello）时退回屏幕比例', () {
      final Size size = MiniWindowLayout.windowSize(
        screen: screen,
        desktopResolution: Size.zero,
      );
      expect(size, const Size(960, 540));
      // 宽有高没有，同样走兜底
      final Size halfZero = MiniWindowLayout.windowSize(
        screen: screen,
        desktopResolution: const Size(1920, 0),
      );
      expect(halfZero, const Size(960, 540));
    });

    test('极小屏撑到最小可读尺寸 160×90，不出现 88×50 这种窗口', () {
      final Size size = MiniWindowLayout.windowSize(
        screen: const Size(200, 100),
        desktopResolution: const Size(1920, 1080),
      );
      expect(size.width, greaterThanOrEqualTo(MiniWindowLayout.minWidth));
      expect(size.height, greaterThanOrEqualTo(MiniWindowLayout.minHeight));
      expect(size, const Size(160, 90));
    });

    test('屏幕尺寸为 0 / 负数 / NaN 时返回最小尺寸而不抛异常', () {
      expect(
        MiniWindowLayout.windowSize(screen: Size.zero, desktopResolution: desktop),
        MiniWindowLayout.minSize,
      );
      expect(
        MiniWindowLayout.windowSize(
          screen: const Size(-100, -100),
          desktopResolution: desktop,
        ),
        MiniWindowLayout.minSize,
      );
      expect(
        MiniWindowLayout.windowSize(
          screen: const Size(double.nan, double.nan),
          desktopResolution: desktop,
        ),
        MiniWindowLayout.minSize,
      );
    });
  });

  group('initialPosition 初始位置', () {
    test('右下角对齐，距右边与下边各留 margin', () {
      final Offset position = MiniWindowLayout.initialPosition(
        screen: const Size(1920, 1080),
        window: const Size(960, 540),
      );
      expect(position, const Offset(936, 516));
    });

    test('自定义 margin 生效', () {
      final Offset position = MiniWindowLayout.initialPosition(
        screen: const Size(1920, 1080),
        window: const Size(960, 540),
        margin: 0,
      );
      expect(position, const Offset(960, 540));
    });

    test('屏幕装不下时夹到 0，不留负坐标', () {
      final Offset position = MiniWindowLayout.initialPosition(
        screen: const Size(300, 200),
        window: const Size(960, 540),
      );
      expect(position, Offset.zero);
    });
  });

  group('snap 贴边吸附', () {
    const Size screen = Size(1920, 1080);
    const Size window = Size(960, 540);

    test('靠近左边（< 16）吸附到 x = 0', () {
      final Offset result = MiniWindowLayout.snap(
        position: const Offset(5, 300),
        screen: screen,
        window: window,
      );
      expect(result, const Offset(0, 300));
    });

    test('靠近上边（< 16）吸附到 y = 0', () {
      final Offset result = MiniWindowLayout.snap(
        position: const Offset(300, 10),
        screen: screen,
        window: window,
      );
      expect(result, const Offset(300, 0));
    });

    test('靠近右边（< 16）吸附到贴右', () {
      final Offset result = MiniWindowLayout.snap(
        position: const Offset(950, 300),
        screen: screen,
        window: window,
      );
      // 1920 - (950 + 960) = 10 < 16
      expect(result, const Offset(960, 300));
    });

    test('靠近下边（< 16）吸附到贴底', () {
      final Offset result = MiniWindowLayout.snap(
        position: const Offset(300, 530),
        screen: screen,
        window: window,
      );
      // 1080 - (530 + 540) = 10 < 16
      expect(result, const Offset(300, 540));
    });

    test('屏幕中间不吸附', () {
      final Offset result = MiniWindowLayout.snap(
        position: const Offset(400, 300),
        screen: screen,
        window: window,
      );
      expect(result, const Offset(400, 300));
    });

    test('距离恰好等于阈值不吸附', () {
      final Offset result = MiniWindowLayout.snap(
        position: const Offset(16, 16),
        screen: screen,
        window: window,
        threshold: 16,
      );
      expect(result, const Offset(16, 16));
    });

    test('自定义阈值生效', () {
      final Offset result = MiniWindowLayout.snap(
        position: const Offset(40, 300),
        screen: screen,
        window: window,
        threshold: 48,
      );
      expect(result, const Offset(0, 300));
    });
  });

  group('clampToScreen 拖出回收', () {
    const Size screen = Size(1920, 1080);
    const Size window = Size(960, 540);

    test('正常位置不被改动', () {
      final Offset result = MiniWindowLayout.clampToScreen(
        position: const Offset(300, 300),
        screen: screen,
        window: window,
      );
      expect(result, const Offset(300, 300));
    });

    test('拖到左上角外时，右下角仍留 48px 在屏内', () {
      final Offset result = MiniWindowLayout.clampToScreen(
        position: const Offset(-5000, -5000),
        screen: screen,
        window: window,
      );
      expect(result, const Offset(-912, -492));
      // 露在屏内的宽度/高度正好是 visible
      expect(result.dx + window.width, 48);
      expect(result.dy + window.height, 48);
    });

    test('拖到右下角外时，左上角仍留 48px 在屏内', () {
      final Offset result = MiniWindowLayout.clampToScreen(
        position: const Offset(5000, 5000),
        screen: screen,
        window: window,
      );
      expect(result, const Offset(1872, 1032));
      expect(screen.width - result.dx, 48);
      expect(screen.height - result.dy, 48);
    });

    test('自定义 visible 生效', () {
      final Offset result = MiniWindowLayout.clampToScreen(
        position: const Offset(-5000, 300),
        screen: screen,
        window: window,
        visible: 120,
      );
      expect(result.dx + window.width, 120);
      expect(result.dy, 300);
    });

    test('窗口比 visible 还小时以窗口为准，不把窗口推出屏外', () {
      final Offset result = MiniWindowLayout.clampToScreen(
        position: const Offset(-200, -200),
        screen: const Size(200, 100),
        window: const Size(20, 20),
        visible: 48,
      );
      expect(result, Offset.zero);
    });

    test('屏幕尺寸为 0 也不抛异常', () {
      final Offset result = MiniWindowLayout.clampToScreen(
        position: const Offset(100, 100),
        screen: Size.zero,
        window: const Size(20, 20),
      );
      expect(result.dx.isFinite, isTrue);
      expect(result.dy.isFinite, isTrue);
    });
  });

  group('健壮性', () {
    test('NaN 位置被当成 0 处理，不把 NaN 传出去', () {
      final Offset snapped = MiniWindowLayout.snap(
        position: const Offset(double.nan, double.nan),
        screen: const Size(1920, 1080),
        window: const Size(960, 540),
      );
      expect(snapped, Offset.zero);

      final Offset clamped = MiniWindowLayout.clampToScreen(
        position: const Offset(double.nan, double.nan),
        screen: const Size(1920, 1080),
        window: const Size(960, 540),
      );
      expect(clamped, Offset.zero);
    });

    test('负尺寸窗口不产生负的初始坐标', () {
      final Offset position = MiniWindowLayout.initialPosition(
        screen: const Size(1920, 1080),
        window: const Size(-100, -100),
      );
      expect(position.dx.isFinite, isTrue);
      expect(position.dy.isFinite, isTrue);
      expect(position.dx, greaterThanOrEqualTo(0));
      expect(position.dy, greaterThanOrEqualTo(0));
    });

    test('clampOpacity 对 NaN / 无穷大的处理', () {
      expect(MiniWindowLayout.clampOpacity(double.nan), 0.3);
      expect(MiniWindowLayout.clampOpacity(double.infinity), 1.0);
      expect(MiniWindowLayout.clampOpacity(double.negativeInfinity), 0.3);
      expect(MiniWindowLayout.clampOpacity(0.6), 0.6);
    });
  });
}
