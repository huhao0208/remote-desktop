import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/models.dart';
import 'package:uu_remote/core/security.dart';

void main() {
  group('防窥档位', () {
    test('四个 key 与官方一致，未知值回落到「不启用」', () {
      expect(PrivacyMode.values.map((PrivacyMode m) => m.key).toList(),
          <String>['off', 'blank', 'screenoff', 'wallpaper']);
      expect(PrivacyMode.fromKey('blank'), PrivacyMode.blank);
      expect(PrivacyMode.fromKey('screenoff'), PrivacyMode.screenoff);
      expect(PrivacyMode.fromKey('nope'), PrivacyMode.off);
      expect(PrivacyMode.fromKey(null), PrivacyMode.off);
    });

    test('每个档位都有文案与说明（面板不留空行）', () {
      for (final PrivacyMode m in PrivacyMode.values) {
        expect(m.label, isNotEmpty);
        expect(m.hint, isNotEmpty);
      }
    });
  });

  group('电源动作', () {
    test('key 对齐官方 ACTION_TYPE_*，未知值返回 null', () {
      expect(PowerAction.values.map((PowerAction a) => a.key).toList(),
          <String>['lock', 'reboot', 'shutdown', 'taskmgr']);
      expect(PowerAction.fromKey('shutdown'), PowerAction.shutdown);
      expect(PowerAction.fromKey('sleep'), isNull);
    });

    test('只有重启和关机需要倒计时', () {
      expect(PowerAction.reboot.needsCountdown, isTrue);
      expect(PowerAction.shutdown.needsCountdown, isTrue);
      expect(PowerAction.lock.needsCountdown, isFalse);
      expect(PowerAction.taskmgr.needsCountdown, isFalse);
    });
  });

  group('agent.hello 安全字段', () {
    AgentHello helloWith(Map<String, dynamic> extra) => AgentHello.fromJson(
          <String, dynamic>{
            'p': 'agent.hello',
            'name': 'MY-PC',
            'os': 'Darwin',
            'screen': <String, dynamic>{'w': 2048, 'h': 1280},
            ...extra,
          },
        );

    test('老 Agent 缺字段时：不支持防窥、只放行关机', () {
      final AgentHello hello = helloWith(<String, dynamic>{});
      expect(hello.autoLock, isFalse);
      expect(hello.privacy, 'off');
      expect(hello.privacyEngine, 'unknown');
      // 老 Agent 一定有 shutdown，但没有别的动作
      expect(hello.supportsPower('shutdown'), isTrue);
      expect(hello.supportsPower('reboot'), isFalse);
    });

    test('新 Agent 全字段解析', () {
      final AgentHello hello = helloWith(<String, dynamic>{
        'auto_lock': true,
        'power': <String>['lock', 'shutdown', 'reboot', 'taskmgr'],
        'privacy': 'blank',
        'privacy_engine': 'overlay',
      });
      expect(hello.autoLock, isTrue);
      expect(hello.privacy, 'blank');
      expect(hello.privacyEngine, 'overlay');
      expect(hello.supportsPower('taskmgr'), isTrue);
      expect(hello.supportsPower('hibernate'), isFalse);
    });

    test('power 传了非字符串元素也不崩', () {
      final AgentHello hello = helloWith(<String, dynamic>{
        'power': <Object?>['lock', null, 42, ''],
      });
      expect(hello.power, <String>['lock', '42']);
      expect(hello.supportsPower('lock'), isTrue);
    });
  });

  group('SecurityState', () {
    test('fromHello 带上引擎与档位', () {
      final SecurityState s = SecurityState.fromHello(
        AgentHello.fromJson(<String, dynamic>{
          'name': 'PC',
          'screen': <String, dynamic>{'w': 1920, 'h': 1080},
          'auto_lock': true,
          'privacy': 'screenoff',
          'privacy_engine': 'overlay',
        }),
      );
      expect(s.autoLock, isTrue);
      expect(s.privacy, PrivacyMode.screenoff);
      expect(s.privacySupported, isTrue);
      expect(s.protectedNow, isTrue);
    });

    test('不支持引擎时 privacySupported=false（面板据此置灰）', () {
      const SecurityState s = SecurityState(engine: 'unsupported');
      expect(s.privacySupported, isFalse);
      // 什么都没开 → 需关注
      expect(s.protectedNow, isFalse);
    });

    test('copyWith：clearError 优先于 error 入参', () {
      const SecurityState s = SecurityState(error: '旧错误');
      expect(s.copyWith(clearError: true).error, isNull);
      expect(s.copyWith(error: '新错误').error, '新错误');
      // 不传 error 也不 clear → 保留旧值（避免无关更新把错误提示擦掉）
      expect(s.copyWith(autoLock: true).error, '旧错误');
    });

    test('仅开自动锁屏也算「已防护」', () {
      const SecurityState s = SecurityState(autoLock: true);
      expect(s.protectedNow, isTrue);
    });
  });

  group('倒计时', () {
    test('携带动作与剩余秒数', () {
      const PowerCountdown c = PowerCountdown(action: PowerAction.shutdown, remain: 12);
      expect(c.action.label, '关机');
      expect(c.remain, 12);
    });
  });
}
