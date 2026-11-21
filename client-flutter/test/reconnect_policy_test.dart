import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/reconnect_policy.dart';

/// `ReconnectPolicy` 决定「断开后等多久再试、试几次、什么时候认输」，
/// 直接对着用户体感（干等 / 疯狂重试 / 卡死在 30 秒）——所以把每个边界钉死。
void main() {
  group('退避序列', () {
    test('默认序列依次为 1/2/4/8/15/30 秒', () {
      final ReconnectPolicy policy = ReconnectPolicy();
      final List<int> seconds = <int>[];
      for (int i = 0; i < 6; i++) {
        seconds.add(policy.next()!.inSeconds);
      }
      expect(seconds, <int>[1, 2, 4, 8, 15, 30]);
      expect(policy.attempts, 6);
      // 6 次还没到上限（默认 8），只是档位已经封顶
      expect(policy.exhausted, isFalse);
      expect(policy.pendingDelay, const Duration(seconds: 30));
    });

    test('超过序列长度后保持最后一档 30 秒，不回落', () {
      final ReconnectPolicy policy = ReconnectPolicy();
      final List<int> seconds = <int>[];
      for (int i = 0; i < 8; i++) {
        seconds.add(policy.next()!.inSeconds);
      }
      expect(seconds, <int>[1, 2, 4, 8, 15, 30, 30, 30]);
      expect(policy.exhausted, isTrue);
    });

    test('自定义序列同样封顶在最后一档', () {
      final ReconnectPolicy policy = ReconnectPolicy(
        delays: const <Duration>[Duration(seconds: 5), Duration(seconds: 7)],
        maxAttempts: 5,
      );
      expect(policy.next()!.inSeconds, 5);
      expect(policy.next()!.inSeconds, 7);
      expect(policy.next()!.inSeconds, 7);
      expect(policy.attempts, 3);
    });
  });

  group('上限与耗尽', () {
    test('达到 maxAttempts 后 next 返回 null 且 exhausted', () {
      final ReconnectPolicy policy = ReconnectPolicy(maxAttempts: 3);
      expect(policy.next(), isNotNull);
      expect(policy.next(), isNotNull);
      expect(policy.next(), isNotNull);
      expect(policy.exhausted, isTrue);
      expect(policy.next(), isNull);
    });

    test('耗尽后持续返回 null，只有 reset 能重开', () {
      final ReconnectPolicy policy = ReconnectPolicy(maxAttempts: 1);
      expect(policy.next(), const Duration(seconds: 1));
      expect(policy.next(), isNull);
      expect(policy.next(), isNull);
      expect(policy.next(), isNull);
      expect(policy.attempts, 1);
    });

    test('reset 后 attempts 归零、exhausted 归 false，并从 1 秒重新开始', () {
      final ReconnectPolicy policy = ReconnectPolicy(maxAttempts: 2);
      policy.next();
      policy.next();
      expect(policy.exhausted, isTrue);

      policy.reset();
      expect(policy.attempts, 0);
      expect(policy.exhausted, isFalse);
      expect(policy.pendingDelay, const Duration(seconds: 1));
      expect(policy.next(), const Duration(seconds: 1));
      expect(policy.next(), const Duration(seconds: 2));
    });

    test('maxAttempts 小于序列长度时提前耗尽', () {
      final ReconnectPolicy policy = ReconnectPolicy(maxAttempts: 2);
      expect(policy.next()!.inSeconds, 1);
      expect(policy.next()!.inSeconds, 2);
      expect(policy.next(), isNull);
      expect(policy.exhausted, isTrue);
    });
  });

  group('pendingDelay', () {
    test('不消费计数，也不改变 exhausted', () {
      final ReconnectPolicy policy = ReconnectPolicy();
      expect(policy.pendingDelay, const Duration(seconds: 1));
      expect(policy.pendingDelay, const Duration(seconds: 1));
      expect(policy.attempts, 0);
      expect(policy.exhausted, isFalse);

      policy.next();
      expect(policy.pendingDelay, const Duration(seconds: 2));
      expect(policy.attempts, 1);
    });

    test('耗尽时为 null', () {
      final ReconnectPolicy policy = ReconnectPolicy(maxAttempts: 1);
      policy.next();
      expect(policy.exhausted, isTrue);
      expect(policy.pendingDelay, isNull);
    });
  });

  group('label 文案', () {
    test('0 次：给出首次等待时长，且不出现「第 0 次」', () {
      final ReconnectPolicy policy = ReconnectPolicy();
      expect(policy.label, '断线后 1 秒开始自动重连');
      expect(policy.label.contains('第 0 次'), isFalse);
      // 只读文案，不影响状态
      expect(policy.attempts, 0);
    });

    test('正常态：编号与秒数都跟下一次尝试对齐', () {
      final ReconnectPolicy policy = ReconnectPolicy();
      policy.next();
      expect(policy.label, '第 2 次自动重连（2 秒后）');
      policy.next();
      policy.next();
      // 已排 3 次，下一拍是 8 秒，所以是「第 4 次」
      expect(policy.label, '第 4 次自动重连（8 秒后）');
    });

    test('耗尽态：提示手动重连', () {
      final ReconnectPolicy policy = ReconnectPolicy(maxAttempts: 2);
      policy.next();
      policy.next();
      expect(policy.label, '自动重连已停止，请手动重连');
      // reset 之后回到 0 次文案
      policy.reset();
      expect(policy.label, '断线后 1 秒开始自动重连');
    });

    test('秒数取整（亚秒档位不出现小数）', () {
      final ReconnectPolicy policy = ReconnectPolicy(
        delays: const <Duration>[Duration(milliseconds: 500)],
        maxAttempts: 2,
      );
      policy.next();
      expect(policy.label, '第 2 次自动重连（0 秒后）');
    });
  });

  group('健壮性', () {
    test('空 delays 不抛异常：直接耗尽，next 为 null', () {
      final ReconnectPolicy policy = ReconnectPolicy(delays: const <Duration>[]);
      expect(policy.exhausted, isTrue);
      expect(policy.next(), isNull);
      expect(policy.next(), isNull);
      expect(policy.pendingDelay, isNull);
      expect(policy.label, '自动重连已停止，请手动重连');
      expect(policy.attempts, 0);
      // reset 也救不回来（没有档位可等），但不崩
      policy.reset();
      expect(policy.exhausted, isTrue);
      expect(policy.next(), isNull);
    });

    test('maxAttempts 为 0 / 负数不抛异常，一上来就是耗尽', () {
      for (final int max in <int>[0, -3]) {
        final ReconnectPolicy policy = ReconnectPolicy(maxAttempts: max);
        expect(policy.exhausted, isTrue);
        expect(policy.next(), isNull);
        expect(policy.pendingDelay, isNull);
        expect(policy.label, '自动重连已停止，请手动重连');
        policy.reset();
        expect(policy.exhausted, isTrue);
        expect(policy.next(), isNull);
      }
    });

    test('入参列表之后被外部修改，不影响已创建的策略', () {
      final List<Duration> delays = <Duration>[const Duration(seconds: 9)];
      final ReconnectPolicy policy = ReconnectPolicy(delays: delays, maxAttempts: 2);
      delays[0] = const Duration(seconds: 99);
      expect(policy.next(), const Duration(seconds: 9));
    });
  });
}
