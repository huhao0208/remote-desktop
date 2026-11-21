import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/mic_switch.dart';

/// 控制端麦克风状态机（协议 v3 §6）。
///
/// 这个类存在的唯一理由是**防止「按钮亮着但没声音」**这种假状态，
/// 所以下面每组用例都围绕「什么情况下必须弹回」来写。
void main() {
  group('能力门控', () {
    test('被控端不支持时直接是 unavailable，且点了没反应', () {
      final MicSwitch mic = MicSwitch(); // supported 默认 false
      expect(mic.state, MicState.unavailable);
      expect(mic.available, isFalse);
      expect(mic.canToggle, isFalse);
      expect(mic.nextIntent, isFalse);

      mic.markOnRequested();
      expect(mic.state, MicState.unavailable, reason: '不可用时不允许进 pending');
    });

    test('能力从有到无 → 归位 unavailable；从无到有 → 回到 off', () {
      final MicSwitch mic = MicSwitch(supported: true);
      mic.markOnRequested();
      mic.confirm(on: true, ok: true);
      expect(mic.isOn, isTrue);

      mic.setSupported(false);
      expect(mic.state, MicState.unavailable);
      expect(mic.isOn, isFalse, reason: '能力没了就不能还显示在喊话');

      mic.setSupported(true);
      expect(mic.state, MicState.off, reason: '不保留上次开关态（协议 §6.6）');
    });
  });

  group('pending 防连点', () {
    test('点开麦后进 pendingOn，此时 canToggle 为假', () {
      final MicSwitch mic = MicSwitch(supported: true);
      mic.markOnRequested();
      expect(mic.state, MicState.pendingOn);
      expect(mic.isPending, isTrue);
      expect(mic.canToggle, isFalse, reason: '连点会让两端状态取决于到达顺序');
    });

    test('回执 on:true 才真的进入 on', () {
      final MicSwitch mic = MicSwitch(supported: true);
      mic.markOnRequested();
      expect(mic.isOn, isFalse, reason: 'pending 期间不算开启');
      mic.confirm(on: true, ok: true);
      expect(mic.state, MicState.on);
      expect(mic.isOn, isTrue);
      expect(mic.error, isNull);
    });

    test('关麦也要等回执，不能点了就认为关了', () {
      final MicSwitch mic = MicSwitch(supported: true);
      mic.markOnRequested();
      mic.confirm(on: true, ok: true);

      mic.markOffRequested();
      expect(mic.state, MicState.pendingOff);
      expect(mic.isOn, isFalse, reason: 'pendingOff 不算 on，但也不算彻底关掉');
      expect(mic.isPending, isTrue);

      mic.confirm(on: false, ok: true);
      expect(mic.state, MicState.off);
    });
  });

  group('失败必须弹回', () {
    test('被控端回 busy → 回到 off 并带原因', () {
      final MicSwitch mic = MicSwitch(supported: true);
      mic.markOnRequested();
      mic.confirm(on: false, ok: false, err: 'busy');
      expect(mic.state, MicState.off);
      expect(mic.error, MicError.busy);
      expect(describeMicError(mic.error), contains('其他人'));
    });

    test('ok:true 但 on:false = Agent 主动关掉了（比如设备被拔），以回执为准', () {
      final MicSwitch mic = MicSwitch(supported: true);
      mic.markOnRequested();
      mic.confirm(on: false, ok: true);
      expect(mic.state, MicState.off);
    });

    test('本地拿不到音轨 → fail 直接回 off', () {
      final MicSwitch mic = MicSwitch(supported: true);
      mic.markOnRequested();
      mic.fail(MicError.noTrack);
      expect(mic.state, MicState.off);
      expect(mic.error, MicError.noTrack);
      expect(describeMicError(mic.error), contains('麦克风'));
    });

    test('pending 超时弹回 off 并标 timeout', () {
      final MicSwitch mic = MicSwitch(supported: true);
      mic.markOnRequested();
      expect(mic.expire(), isTrue);
      expect(mic.state, MicState.off);
      expect(mic.error, MicError.timeout);

      // 迟到的回执不能再把它拉成 on（用户已经看到超时提示了）
      expect(mic.expire(), isFalse, reason: '已不在 pending 就不再重复超时');
    });

    test('迟到回执仍然生效（不是超时就直接丢弃）——但状态由回执决定', () {
      final MicSwitch mic = MicSwitch(supported: true);
      mic.markOnRequested();
      mic.expire();
      mic.confirm(on: true, ok: true);
      expect(mic.state, MicState.on, reason: 'Agent 真的开了，UI 就必须如实反映');
    });
  });

  group('未知错误码', () {
    test('解析不了的 err 归 unknown，但绝不吞掉失败', () {
      expect(parseMicError('something_new'), MicError.unknown);
      expect(parseMicError(null), MicError.unknown);
      expect(describeMicError(MicError.unknown), isNotEmpty);

      final MicSwitch mic = MicSwitch(supported: true);
      mic.markOnRequested();
      mic.confirm(on: false, ok: false, err: 'something_new');
      expect(mic.state, MicState.off);
      expect(mic.error, MicError.unknown);
    });

    test('常见写法都能认（no_track / noTrack / no-mic 之外的都归 unknown）', () {
      expect(parseMicError('no_track'), MicError.noTrack);
      expect(parseMicError('noTrack'), MicError.noTrack);
      expect(parseMicError('NO_AUDIO'), MicError.noAudio);
      expect(parseMicError('unsupported'), MicError.unsupported);
    });
  });

  group('重置', () {
    test('reset 清空错误并回 off，不改变可用性', () {
      final MicSwitch mic = MicSwitch(supported: true);
      mic.markOnRequested();
      mic.confirm(on: true, ok: true);
      mic.fail(MicError.busy);

      mic.reset();
      expect(mic.state, MicState.off);
      expect(mic.error, isNull);
      expect(mic.available, isTrue);

      final MicSwitch bad = MicSwitch();
      bad.reset();
      expect(bad.state, MicState.unavailable, reason: 'reset 不能把不支持变成支持');
    });
  });
}