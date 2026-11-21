import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/mouse_mode.dart';

void main() {
  group('三模式文案', () {
    test('label 依次为 使用被控端鼠标 / 使用主控端鼠标 / 智能鼠标', () {
      expect(MouseMode.remote.label, '使用被控端鼠标');
      expect(MouseMode.control.label, '使用主控端鼠标');
      expect(MouseMode.auto.label, '智能鼠标');
    });

    test('hint 三值非空且互不相同', () {
      final List<String> hints = MouseMode.values
          .map((MouseMode m) => m.hint)
          .toList();
      for (final String h in hints) {
        expect(h, isNotEmpty);
      }
      expect(hints.toSet().length, 3);
    });

    test('只有 control 直接发相对位移、直接隐藏远端光标', () {
      expect(MouseMode.remote.sendsRelativeMove, isFalse);
      expect(MouseMode.control.sendsRelativeMove, isTrue);
      // auto 的实际行为由策略决定，静态回答必须是 false
      expect(MouseMode.auto.sendsRelativeMove, isFalse);

      expect(MouseMode.remote.hidesRemoteCursor, isFalse);
      expect(MouseMode.control.hidesRemoteCursor, isTrue);
      expect(MouseMode.auto.hidesRemoteCursor, isFalse);
    });
  });

  group('MouseSettings', () {
    test('默认：remote + 非游戏模式 + 1.0 倍速', () {
      const MouseSettings s = MouseSettings();
      expect(s.mode, MouseMode.remote);
      expect(s.gameMode, isFalse);
      expect(s.speed, 1.0);
      expect(s.effectiveSpeed, 1.0);
    });

    test('effectiveSpeed：非游戏模式恒为 1，无视 speed 字段', () {
      const MouseSettings s = MouseSettings(speed: 2.5);
      expect(s.effectiveSpeed, 1.0);
    });

    test('effectiveSpeed：游戏模式钳到 0.5–3.0', () {
      expect(
        const MouseSettings(gameMode: true, speed: 0.1).effectiveSpeed,
        MouseSettings.minSpeed,
      );
      expect(
        const MouseSettings(gameMode: true, speed: 99).effectiveSpeed,
        MouseSettings.maxSpeed,
      );
      expect(
        const MouseSettings(gameMode: true, speed: 2.0).effectiveSpeed,
        2.0,
      );
    });

    test('copyWith 只改传入字段', () {
      const MouseSettings base = MouseSettings();
      final MouseSettings next = base.copyWith(mode: MouseMode.control);
      expect(next.mode, MouseMode.control);
      expect(next.gameMode, isFalse);
      expect(next.speed, 1.0);
      // 原值不变（不可变值语义）
      expect(base.mode, MouseMode.remote);
    });

    test('toJson / fromJson 往返一致', () {
      const MouseSettings s = MouseSettings(
        mode: MouseMode.auto,
        gameMode: true,
        speed: 1.75,
      );
      final MouseSettings back = MouseSettings.fromJson(s.toJson());
      expect(back.mode, MouseMode.auto);
      expect(back.gameMode, isTrue);
      expect(back.speed, 1.75);
      expect(back.effectiveSpeed, 1.75);
    });

    test('fromJson：空 JSON 退全部默认', () {
      final MouseSettings s = MouseSettings.fromJson(<String, dynamic>{});
      expect(s.mode, MouseMode.remote);
      expect(s.gameMode, isFalse);
      expect(s.speed, 1.0);
    });

    test('fromJson：speed 类型错（"abc"）退默认 1.0', () {
      final MouseSettings s = MouseSettings.fromJson(<String, dynamic>{
        'speed': 'abc',
      });
      expect(s.speed, 1.0);
      expect(s.effectiveSpeed, 1.0);
    });

    test('fromJson：speed 越界被钳制（99 → 3.0，0.1 → 0.5）', () {
      expect(
        MouseSettings.fromJson(<String, dynamic>{'speed': 99}).speed,
        MouseSettings.maxSpeed,
      );
      expect(
        MouseSettings.fromJson(<String, dynamic>{'speed': 0.1}).speed,
        MouseSettings.minSpeed,
      );
    });

    test('fromJson：未知 mode 名退 remote，gameMode 类型错退 false', () {
      final MouseSettings s = MouseSettings.fromJson(<String, dynamic>{
        'mode': 'turbo',
        'gameMode': 1,
      });
      expect(s.mode, MouseMode.remote);
      expect(s.gameMode, isFalse);
    });
  });

  group('RelativeCursor', () {
    test('默认落在屏幕中心', () {
      final RelativeCursor c = RelativeCursor();
      expect(c.x, 0.5);
      expect(c.y, 0.5);
      expect(c.atEdge, isFalse);
    });

    test('构造参数越界被钳到 0..1', () {
      final RelativeCursor c = RelativeCursor(x: -3, y: 8);
      expect(c.x, 0.0);
      expect(c.y, 1.0);
    });

    test('moveBy 累加并返回实际位移', () {
      final RelativeCursor c = RelativeCursor();
      final ({double dx, double dy}) d = c.moveBy(0.25, -0.25);
      expect(d.dx, closeTo(0.25, 1e-12));
      expect(d.dy, closeTo(-0.25, 1e-12));
      expect(c.x, closeTo(0.75, 1e-12));
      expect(c.y, closeTo(0.25, 1e-12));
      expect(c.atEdge, isFalse);
    });

    test('撞边界时裁剪位移，之后贴边不再产生位移', () {
      final RelativeCursor c = RelativeCursor(x: 0.8, y: 0.5);
      final ({double dx, double dy}) first = c.moveBy(0.5, 0.0);
      // 只剩 0.2 可走，返回值必须是裁掉之后的量
      expect(first.dx, closeTo(0.2, 1e-12));
      expect(first.dy, 0.0);
      expect(c.x, 1.0);
      expect(c.atEdge, isTrue);

      final ({double dx, double dy}) second = c.moveBy(0.1, 0.0);
      expect(second.dx, 0.0);
      expect(second.dy, 0.0);
      expect(c.x, 1.0);
    });

    test('负方向撞到 0 也裁剪，并置 atEdge', () {
      final RelativeCursor c = RelativeCursor(x: 0.1, y: 0.5);
      final ({double dx, double dy}) d = c.moveBy(-0.4, 0.0);
      expect(d.dx, closeTo(-0.1, 1e-12));
      expect(c.x, 0.0);
      expect(c.atEdge, isTrue);
    });

    test('speed 只在传入时生效，非法 speed 按 1.0 处理', () {
      final RelativeCursor c = RelativeCursor(x: 0.0, y: 0.5);
      final ({double dx, double dy}) fast = c.moveBy(0.1, 0.0, speed: 2.0);
      expect(fast.dx, closeTo(0.2, 1e-12));
      expect(c.x, closeTo(0.2, 1e-12));

      final RelativeCursor c2 = RelativeCursor(x: 0.0, y: 0.5);
      final ({double dx, double dy}) bad = c2.moveBy(0.1, 0.0, speed: 0);
      expect(bad.dx, closeTo(0.1, 1e-12));
    });

    test('非有限输入被吞掉，坐标不被污染', () {
      final RelativeCursor c = RelativeCursor();
      final ({double dx, double dy}) d = c.moveBy(double.nan, 0.1);
      expect(d.dx, 0.0);
      expect(d.dy, 0.0);
      expect(c.x, 0.5);
      expect(c.y, 0.5);
    });

    test('reset 回到指定位置（默认中心）', () {
      final RelativeCursor c = RelativeCursor(x: 0.9, y: 0.1);
      c.reset();
      expect(c.x, 0.5);
      expect(c.y, 0.5);
      expect(c.atEdge, isFalse);

      c.reset(x: 1.0, y: 0.0);
      expect(c.atEdge, isTrue);
    });
  });

  group('AutoMousePolicy', () {
    test('低 RTT 且未拖拽 → remote', () {
      final AutoMousePolicy p = AutoMousePolicy();
      expect(p.current, MouseMode.remote);
      expect(
        p.decide(rttMs: 20, dragging: false, since: Duration.zero),
        MouseMode.remote,
      );
    });

    test('RTT 高于阈值 → control', () {
      final AutoMousePolicy p = AutoMousePolicy();
      expect(
        p.decide(rttMs: 61, dragging: false, since: Duration.zero),
        MouseMode.control,
      );
      expect(p.current, MouseMode.control);
    });

    test('RTT 恰好等于阈值不算高延迟（严格大于）', () {
      final AutoMousePolicy p = AutoMousePolicy();
      expect(
        p.decide(rttMs: 60, dragging: false, since: Duration.zero),
        MouseMode.remote,
      );
    });

    test('拖拽中 → control（即使 RTT 很低）', () {
      final AutoMousePolicy p = AutoMousePolicy();
      expect(
        p.decide(rttMs: 10, dragging: true, since: Duration.zero),
        MouseMode.control,
      );
    });

    test('滞回：切 control 后 1.9s 内 RTT 恢复仍 control，2.1s 后回 remote', () {
      final AutoMousePolicy p = AutoMousePolicy();
      expect(
        p.decide(rttMs: 120, dragging: false, since: Duration.zero),
        MouseMode.control,
      );
      // 1.9s：还在 recoverAfter(2s) 窗口内
      expect(
        p.decide(
          rttMs: 20,
          dragging: false,
          since: const Duration(milliseconds: 1900),
        ),
        MouseMode.control,
      );
      // 2.1s：窗口已过，允许回默认态
      expect(
        p.decide(
          rttMs: 20,
          dragging: false,
          since: const Duration(milliseconds: 2100),
        ),
        MouseMode.remote,
      );
      expect(p.current, MouseMode.remote);
    });

    test('无采样（rttMs=0 / 负数 / NaN）按 remote 处理，不因缺数据切模式', () {
      for (final double rtt in <double>[0.0, -1.0, double.nan]) {
        final AutoMousePolicy p = AutoMousePolicy();
        expect(
          p.decide(rttMs: rtt, dragging: false, since: Duration.zero),
          MouseMode.remote,
        );
      }
      // 已因拖拽进入 control 后，采样缺失也要靠滞回窗口退出，而非立刻跳
      final AutoMousePolicy p = AutoMousePolicy();
      p.decide(rttMs: 0, dragging: true, since: Duration.zero);
      expect(
        p.decide(
          rttMs: 0,
          dragging: false,
          since: const Duration(milliseconds: 500),
        ),
        MouseMode.control,
      );
      expect(
        p.decide(rttMs: 0, dragging: false, since: const Duration(seconds: 3)),
        MouseMode.remote,
      );
    });

    test('reset 后回默认 remote', () {
      final AutoMousePolicy p = AutoMousePolicy();
      p.decide(rttMs: 200, dragging: false, since: Duration.zero);
      expect(p.current, MouseMode.control);
      p.reset();
      expect(p.current, MouseMode.remote);
      expect(
        p.decide(rttMs: 10, dragging: false, since: Duration.zero),
        MouseMode.remote,
      );
    });
  });
}
