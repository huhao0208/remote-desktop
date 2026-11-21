import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/client_lock.dart';

/// 内存版存储：替代 SharedPreferences，记录写入次数与内容，并可模拟异常。
///
/// 走注入而不是真 SharedPreferences，单测才不需要 platform channel，
/// 也能直接断言「存档里到底存了什么」（比如绝不含明文密码）。
class _FakeStore {
  /// 键 → 值，模拟本地存档。
  final Map<String, String> values = <String, String>{};

  /// 读取是否抛异常（模拟存档损坏/无权限）。
  bool readThrows = false;

  /// 写入是否抛异常（模拟磁盘满/权限不足）。
  bool writeThrows = false;

  /// 读取次数。
  int reads = 0;

  /// 写入次数（用来断言非法密码一个字都不写）。
  int writes = 0;

  Future<String?> read(String key) async {
    reads++;
    if (readThrows) throw StateError('读存储失败');
    return values[key];
  }

  Future<void> write(String key, String value) async {
    if (writeThrows) throw StateError('写存储失败');
    writes++;
    values[key] = value;
  }

  Future<void> remove(String key) async {
    if (writeThrows) throw StateError('删存储失败');
    values.remove(key);
  }

  ClientLock lock({
    DateTime Function()? now,
    int maxAttempts = 5,
    Duration lockout = const Duration(minutes: 1),
  }) => ClientLock(
    read: read,
    write: write,
    remove: remove,
    now: now,
    maxAttempts: maxAttempts,
    lockout: lockout,
  );
}

/// 可推进的假时钟：冷却与倒计时都靠 `now` 注入，测试才能秒级推进。
class _Clock {
  DateTime current = DateTime(2026, 11, 21, 12);

  DateTime now() => current;

  void advance(Duration duration) {
    current = current.add(duration);
  }
}

/// sha256 hex 的形状：64 位小写十六进制。
final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

void main() {
  group('密码强度校验（checkPassword）', () {
    test('7 位：太短', () {
      expect(ClientLock.checkPassword('Abc1234'), PasswordVerdict.tooShort);
    });

    test('8 位且字母+数字：通过（下界）', () {
      expect(ClientLock.checkPassword('Abcd1234'), PasswordVerdict.ok);
    });

    test('16 位且字母+数字：通过（上界）', () {
      expect(ClientLock.checkPassword('Abcd123456789012'), PasswordVerdict.ok);
    });

    test('17 位：太长', () {
      expect(
        ClientLock.checkPassword('Abcd1234567890123'),
        PasswordVerdict.tooLong,
      );
    });

    test('8 位纯数字：太简单', () {
      expect(ClientLock.checkPassword('12345678'), PasswordVerdict.tooWeak);
    });

    test('8 位纯字母：太简单', () {
      expect(ClientLock.checkPassword('abcdefgh'), PasswordVerdict.tooWeak);
    });

    test('含符号：字母+符号两类，通过', () {
      expect(ClientLock.checkPassword('Abcdefg!'), PasswordVerdict.ok);
    });

    test('含中文：中文算「其它」一类，与数字组合即通过', () {
      expect(ClientLock.checkPassword('密码密码密码1234'), PasswordVerdict.ok);
    });

    test('纯中文只有一类：太简单', () {
      expect(ClientLock.checkPassword('密码密码密码密码密码'), PasswordVerdict.tooWeak);
    });
  });

  group('设置密码（setPassword）', () {
    test('成功返回 null，存档只落 64 位 sha256 hex 且不含明文', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;

      expect(await lock.setPassword('Abcd1234!'), isNull);

      expect(lock.hasPassword, isTrue);
      final String? stored = store.values[ClientLock.keyHash];
      expect(stored, isNotNull);
      expect(_sha256Hex.hasMatch(stored!), isTrue, reason: '必须是 64 位小写 hex');
      expect(store.values[ClientLock.keyEnabled], '1');
      // 全部存档值都不得包含明文（含前缀片段，防止「截断后存一半」）
      for (final String value in store.values.values) {
        expect(value.contains('Abcd1234!'), isFalse);
        expect(value.contains('Abcd'), isFalse);
        expect(value.contains('1234'), isFalse);
      }
    });

    test('同密码摘要稳定：两次设置得到同一个 hash', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;

      await lock.setPassword('Abcd1234');
      final String first = store.values[ClientLock.keyHash]!;

      await lock.clearPassword();
      await lock.setPassword('Abcd1234');

      expect(store.values[ClientLock.keyHash], first);
    });

    test('太短：返回中文文案，且一个字节都不写存档', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;

      final String? message = await lock.setPassword('Abc123');

      expect(message, '密码长度需 8-16 位');
      expect(store.writes, 0);
      expect(lock.hasPassword, isFalse);
    });

    test('太简单：返回中文文案，不写存档', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;

      final String? message = await lock.setPassword('12345678');

      expect(message, '密码需包含字母和数字两类以上');
      expect(store.writes, 0);
      expect(lock.hasPassword, isFalse);
    });
  });

  group('密码校验（verifyPassword）', () {
    test('正确密码：返回 true 并解锁', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;
      await lock.setPassword('Abcd1234');
      lock.lock();
      expect(lock.isLocked, isTrue);

      expect(await lock.verifyPassword('Abcd1234'), isTrue);
      expect(lock.isLocked, isFalse);
      expect(lock.lastError, isNull);
      expect(lock.attemptsLeft, 5);
    });

    test('错误密码：返回 false，失败原因与剩余次数随之更新', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;
      await lock.setPassword('Abcd1234');

      expect(await lock.verifyPassword('Abcd12345'), isFalse);
      expect(lock.lastError, '密码错误，还可尝试 4 次');
      expect(lock.attemptsLeft, 4);
      expect(lock.isLocked, isFalse, reason: '失败不该主动上锁，只累计计数');
    });

    test('没设密码：直接返回 true（没上锁就不该要求密码）', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;

      expect(lock.hasPassword, isFalse);
      expect(await lock.verifyPassword('随便'), isTrue);
      expect(lock.isLocked, isFalse);
    });

    test('中途成功一次会清零失败计数', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;
      await lock.setPassword('Abcd1234');

      for (int i = 0; i < 4; i++) {
        expect(await lock.verifyPassword('错的'), isFalse);
      }
      expect(lock.attemptsLeft, 1);

      expect(await lock.verifyPassword('Abcd1234'), isTrue);
      expect(lock.attemptsLeft, 5);
    });
  });

  group('失败冷却', () {
    test('连续失败 5 次进入冷却：剩余毫秒 > 0、可尝试次数归零', () async {
      final _Clock clock = _Clock();
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock(now: clock.now);
      await lock.ready;
      await lock.setPassword('Abcd1234');

      for (int i = 0; i < 5; i++) {
        expect(await lock.verifyPassword('错的错的'), isFalse);
      }

      expect(lock.cooldownRemainingMs, greaterThan(0));
      expect(lock.attemptsLeft, 0);
      expect(lock.lastError, contains('尝试次数过多'));
    });

    test('冷却期内即使密码正确也拒绝', () async {
      final _Clock clock = _Clock();
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock(now: clock.now);
      await lock.ready;
      await lock.setPassword('Abcd1234');

      for (int i = 0; i < 5; i++) {
        await lock.verifyPassword('错的错的');
      }
      clock.advance(const Duration(seconds: 30));

      expect(await lock.verifyPassword('Abcd1234'), isFalse);
      expect(lock.lastError, contains('秒后重试'));
    });

    test('冷却结束后正确密码可以通过', () async {
      final _Clock clock = _Clock();
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock(now: clock.now);
      await lock.ready;
      await lock.setPassword('Abcd1234');

      for (int i = 0; i < 5; i++) {
        await lock.verifyPassword('错的错的');
      }
      clock.advance(const Duration(seconds: 61));

      expect(lock.cooldownRemainingMs, 0);
      expect(lock.attemptsLeft, 5);
      expect(await lock.verifyPassword('Abcd1234'), isTrue);
    });
  });

  group('手动上锁与静默解锁', () {
    test('lock 上锁、unlockQuietly 不校验直接解锁', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;
      await lock.setPassword('Abcd1234');

      lock.lock();
      expect(lock.isLocked, isTrue);

      lock.unlockQuietly();
      expect(lock.isLocked, isFalse);
      expect(lock.lastError, isNull);
    });

    test('没设密码时 lock 不上锁（否则界面上永远解不开）', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;

      lock.lock();
      expect(lock.isLocked, isFalse);
    });

    test('clearPassword 后无密码、未锁定、开关全关、存档已清', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;
      await lock.setPassword('Abcd1234');
      lock.lock();

      await lock.clearPassword();

      expect(lock.hasPassword, isFalse);
      expect(lock.isLocked, isFalse);
      for (final AutoLockTrigger trigger in AutoLockTrigger.values) {
        expect(lock.isTriggerEnabled(trigger), isFalse);
      }
      expect(store.values.containsKey(ClientLock.keyHash), isFalse);
      expect(store.values[ClientLock.keyEnabled], '0');
      expect(store.values.containsKey(ClientLock.keyTriggers), isFalse);
    });
  });

  group('自动锁定策略（shouldLock / setTrigger）', () {
    test('存档为空时三条开关默认全开', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;

      for (final AutoLockTrigger trigger in AutoLockTrigger.values) {
        expect(lock.isTriggerEnabled(trigger), isTrue);
      }
    });

    test('没设密码时任何开关都不上锁', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;

      for (final AutoLockTrigger trigger in AutoLockTrigger.values) {
        expect(lock.shouldLock(trigger), isFalse);
      }
    });

    test('设密码后按开关决定：关掉 onStart 只影响它自己', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;
      await lock.setPassword('Abcd1234');

      await lock.setTrigger(AutoLockTrigger.onStart, false);

      expect(lock.shouldLock(AutoLockTrigger.onStart), isFalse);
      expect(lock.shouldLock(AutoLockTrigger.onClose), isTrue);
      expect(lock.shouldLock(AutoLockTrigger.duringAssist), isTrue);
      expect(store.values[ClientLock.keyTriggers], 'onClose,duringAssist');
    });

    test('开关状态会持久化，重建实例后读回同样的开关', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock first = store.lock();
      await first.ready;
      await first.setPassword('Abcd1234');
      await first.setTrigger(AutoLockTrigger.onClose, false);
      await first.setTrigger(AutoLockTrigger.duringAssist, false);

      final ClientLock second = store.lock();
      await second.ready;

      expect(second.hasPassword, isTrue);
      expect(second.isTriggerEnabled(AutoLockTrigger.onClose), isFalse);
      expect(second.isTriggerEnabled(AutoLockTrigger.duringAssist), isFalse);
      expect(second.isTriggerEnabled(AutoLockTrigger.onStart), isTrue);
      expect(second.shouldLock(AutoLockTrigger.onStart), isTrue);
    });

    test('duringAssist 只回答开关状态，不主动上锁（由调用方在协助开始时 lock）', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;
      await lock.setPassword('Abcd1234');

      expect(lock.shouldLock(AutoLockTrigger.duringAssist), isTrue);
      expect(lock.isLocked, isFalse);

      lock.lock();
      expect(lock.isLocked, isTrue);
      lock.unlockQuietly();
      expect(lock.isLocked, isFalse, reason: '协助结束应当静默解锁');
    });

    test('三个触发点的中文名与副标题齐备', () {
      expect(AutoLockTrigger.onClose.label, '关闭主界面时');
      expect(AutoLockTrigger.duringAssist.label, '远程协助期间');
      expect(AutoLockTrigger.onStart.label, '启动时');
      for (final AutoLockTrigger trigger in AutoLockTrigger.values) {
        expect(trigger.hint, isNotEmpty);
      }
      expect(AutoLockTrigger.duringAssist.hint, contains('自动解锁'));
    });
  });

  group('存储异常不崩', () {
    test('读存档抛异常：ready 正常完成，降级为没设密码', () async {
      final _FakeStore store = _FakeStore();
      store.readThrows = true;
      final ClientLock lock = store.lock();

      await lock.ready;

      expect(lock.hasPassword, isFalse);
      expect(lock.isLocked, isFalse);
      expect(await lock.verifyPassword('随便'), isTrue);
    });

    test('写存档抛异常：setPassword 不抛，且本次会话仍可用', () async {
      final _FakeStore store = _FakeStore();
      store.writeThrows = true;
      final ClientLock lock = store.lock();
      await lock.ready;

      expect(await lock.setPassword('Abcd1234'), isNull);
      expect(lock.hasPassword, isTrue);
      expect(await lock.verifyPassword('Abcd1234'), isTrue);
    });

    test('setTrigger 抛异常也不抛出到调用方', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;
      await lock.setPassword('Abcd1234');
      store.writeThrows = true;

      await lock.setTrigger(AutoLockTrigger.onStart, false);

      expect(lock.isTriggerEnabled(AutoLockTrigger.onStart), isFalse);
    });

    test('clearPassword 时存储异常也不抛', () async {
      final _FakeStore store = _FakeStore();
      final ClientLock lock = store.lock();
      await lock.ready;
      await lock.setPassword('Abcd1234');
      store.writeThrows = true;

      await lock.clearPassword();

      expect(lock.hasPassword, isFalse);
    });
  });

  group('短信验证码倒计时（SmsCodeTimer）', () {
    test('初始可发送，剩余 0 秒', () {
      final SmsCodeTimer timer = SmsCodeTimer(
        now: () => DateTime(2026, 11, 21),
      );

      expect(timer.remainingSeconds, 0);
      expect(timer.canResend, isTrue);
    });

    test('发送后进入 60 秒倒计时，冷却中不得重复发', () {
      final _Clock clock = _Clock();
      final SmsCodeTimer timer = SmsCodeTimer(now: clock.now);

      expect(timer.start(), isTrue);
      expect(timer.remainingSeconds, 60);
      expect(timer.canResend, isFalse);
      expect(timer.start(), isFalse);
    });

    test('倒计时按 now 递减：59 秒时剩 1 秒', () {
      final _Clock clock = _Clock();
      final SmsCodeTimer timer = SmsCodeTimer(now: clock.now);
      timer.start();

      clock.advance(const Duration(seconds: 59));

      expect(timer.remainingSeconds, 1);
      expect(timer.canResend, isFalse);
    });

    test('前进 61 秒后可重发', () {
      final _Clock clock = _Clock();
      final SmsCodeTimer timer = SmsCodeTimer(now: clock.now);
      timer.start();
      final DateTime firstStart = clock.current;

      clock.advance(const Duration(seconds: 61));

      expect(timer.remainingSeconds, 0);
      expect(timer.canResend, isTrue);
      expect(timer.start(), isTrue);
      expect(clock.current.isAfter(firstStart), isTrue);
    });

    test('reset 立即回到可发送状态', () {
      final _Clock clock = _Clock();
      final SmsCodeTimer timer = SmsCodeTimer(now: clock.now);
      timer.start();

      timer.reset();

      expect(timer.remainingSeconds, 0);
      expect(timer.canResend, isTrue);
      expect(timer.start(), isTrue);
    });

    test('系统时间被往回调也不会超过 60 秒', () {
      final _Clock clock = _Clock();
      final SmsCodeTimer timer = SmsCodeTimer(now: clock.now);
      timer.start();

      clock.advance(const Duration(seconds: -30));

      expect(timer.remainingSeconds, 60);
    });
  });
}
