import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 三种自动锁定触发点（对齐官方「客户端锁」的三条策略）。
///
/// 为什么用枚举而不是三个 bool：设置页要按固定顺序渲染开关，每个开关还各有
/// 中文名与副标题；枚举同时给出了顺序、文案与「新增触发点编译器不会漏」。
/// 存档侧直接落 [name]，于是加减枚举值只会丢掉认不出的那一项，不会连累其它开关。
enum AutoLockTrigger {
  /// 关闭主界面时。
  onClose,

  /// 远程协助本设备期间（协助结束后自动解锁）。
  duringAssist,

  /// 启动时。
  onStart;

  /// 设置项标题。
  String get label => switch (this) {
    AutoLockTrigger.onClose => '关闭主界面时',
    AutoLockTrigger.duringAssist => '远程协助期间',
    AutoLockTrigger.onStart => '启动时',
  };

  /// 设置项副标题：开关自己说不清楚「上锁之后会怎样」，必须补一句。
  String get hint => switch (this) {
    AutoLockTrigger.onClose => '关闭主窗口后立即锁定，下次打开需先解锁才能看到设备列表',
    AutoLockTrigger.duringAssist => '被别人远程控制期间保持锁定，结束后自动解锁',
    AutoLockTrigger.onStart => '每次启动客户端先上锁，防止旁人直接进入',
  };

  /// 从存档反查（`client_lock_triggers` 存的是逗号分隔的 [name]）。
  ///
  /// 返回 null 而不是抛异常：新旧版本互相读写同一份存档是常态，
  /// 认不出的名字丢掉就好，绝不能因此让启动失败。
  static AutoLockTrigger? fromName(String name) {
    for (final AutoLockTrigger trigger in AutoLockTrigger.values) {
      if (trigger.name == name) return trigger;
    }
    return null;
  }
}

/// 解锁方式：官方给了密码与短信验证码两条路。
///
/// 这里只做枚举而不做流程：短信那条路要走服务端 `forgotPassword` → `getCode`，
/// 属于网络层的事；客户端锁只负责「倒计时 + 冷却」这类纯状态机。
enum UnlockMethod {
  /// 安全密码（本地 sha256 校验）。
  password,

  /// 短信验证码（服务端下发，60s 可重发，见 [SmsCodeTimer]）。
  smsCode,
}

/// 密码强度校验结果。
///
/// 单用 `bool` 不够用：设置页要把「太短」和「太简单」提示成不同文案，
/// 而 `tooWeak` 是最容易被用户忽略的一类（`12345678` 长度合法但形同虚设）。
enum PasswordVerdict {
  /// 通过。
  ok,

  /// 少于 [ClientLock.minLength] 位。
  tooShort,

  /// 多于 [ClientLock.maxLength] 位。
  tooLong,

  /// 字符类别不足两类（纯数字 / 纯字母 / 纯中文）。
  tooWeak,
}

/// 客户端锁：安全密码 + 三种自动锁定策略 + 失败冷却（纯逻辑，不碰页面/网络）。
///
/// 为什么把存储做成注入的读写函数：主体是**纯逻辑**，单测才能不依赖
/// SharedPreferences 与 platform channel；主控接线时只要把三个函数接到
/// `SharedPreferences.getString / setString / remove` 即可，本文件因此不需要
/// import flutter 的任何东西。
///
/// 安全取舍：
/// 1. 只存 sha256 摘要（[keyHash]），任何路径都不落明文——包括错误日志；
/// 2. 不加 salt：salt 也得存进同一条本地存档，对能读到文件的人没有额外收益，
///    真正的防爆破手段是 [maxAttempts] 次后的 [lockout] 冷却；
/// 3. 所有存储读写失败一律吞掉并降级为「没设密码」，启动不能因为存档坏了就崩。
class ClientLock {
  ClientLock({
    Future<String?> Function(String key)? read,
    Future<void> Function(String key, String value)? write,
    Future<void> Function(String key)? remove,
    DateTime Function()? now,
    int maxAttempts = 5,
    Duration lockout = const Duration(minutes: 1),
  }) : _read = read ?? _noRead,
       _write = write ?? _noWrite,
       _remove = remove ?? _noRemove,
       _now = now ?? DateTime.now,
       // 私有字段不能写成 `this._maxAttempts`（命名参数不允许下划线开头）。
       // ignore: prefer_initializing_formals
       _maxAttempts = maxAttempts,
       // ignore: prefer_initializing_formals
       _lockout = lockout {
    // 构造即异步加载。调用方必须在首帧前 `await ready`，否则 [hasPassword]
    // 还是 false，解锁界面会闪一下（见回报里的接线注意点）。
    _ready = _load();
  }

  /// 密码最短长度（官方 8-16 位）。
  static const int minLength = 8;

  /// 密码最长长度。
  static const int maxLength = 16;

  /// 密码摘要存档键：sha256 hex（64 字符小写）。
  static const String keyHash = 'client_lock_hash';

  /// 自动锁定开关存档键：逗号分隔的 [AutoLockTrigger.name]。
  static const String keyTriggers = 'client_lock_triggers';

  /// 是否已启用客户端锁：`'1'` / `'0'`。
  ///
  /// 单独存一个开关而不是「有 hash 就算启用」：清密码时要能明确表达
  /// 「用户主动关掉了」，避免残留 hash 让界面误判。
  static const String keyEnabled = 'client_lock_enabled';

  static Future<String?> _noRead(String key) async => null;

  static Future<void> _noWrite(String key, String value) async {}

  static Future<void> _noRemove(String key) async {}

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final Future<void> Function(String key) _remove;
  final DateTime Function() _now;

  /// 连续失败多少次进入冷却。
  final int _maxAttempts;

  /// 冷却时长。
  final Duration _lockout;

  /// 首次加载的未来，见 [ready]。
  late final Future<void> _ready;

  /// 密码摘要（null = 没设过）。
  String? _hash;

  /// 客户端锁总开关。
  bool _enabled = false;

  /// 已打开的触发点。存档里没有这个键时默认三条全开——
  /// 没设密码时 [shouldLock] 本来就不会上锁，默认全开不会打扰任何人。
  final Set<AutoLockTrigger> _triggers = <AutoLockTrigger>{
    ...AutoLockTrigger.values,
  };

  /// 当前是否处于锁定态。
  bool _locked = false;

  /// 当前冷却窗口内的连续失败次数。
  int _failures = 0;

  /// 冷却截止时间（null = 不在冷却）。
  DateTime? _lockUntil;

  /// 最近一次失败原因。
  String? _lastError;

  /// 存储加载完成。UI 首帧前 `await` 一次，避免先闪解锁界面再消失。
  Future<void> get ready => _ready;

  /// 是否已设置密码（同时要求总开关为开）。
  bool get hasPassword => _enabled && (_hash?.isNotEmpty ?? false);

  /// 当前是否处于锁定态（解锁界面可见）。
  bool get isLocked => _locked;

  /// 密码强度校验：长度 + 至少两类字符。
  ///
  /// 类别按「数字 / 英文字母 / 其它（符号与中文）」划分：纯中文只有一类，
  /// 同样算 [PasswordVerdict.tooWeak]——官方只要求「安全密码」，
  /// 四个汉字密码的暴力空间远小于字母+数字混合。
  static PasswordVerdict checkPassword(String password) {
    if (password.length < minLength) return PasswordVerdict.tooShort;
    if (password.length > maxLength) return PasswordVerdict.tooLong;
    if (_characterClasses(password) < 2) return PasswordVerdict.tooWeak;
    return PasswordVerdict.ok;
  }

  /// 设置密码：先校验，再存 sha256 摘要（**绝不存明文**）。
  ///
  /// 返回 null 表示成功，否则返回中文错误文案（直接可以丢给 SnackBar）。
  Future<String?> setPassword(String password) async {
    final PasswordVerdict verdict = checkPassword(password);
    if (verdict != PasswordVerdict.ok) return _verdictMessage(verdict);
    // 等首次加载完成再改内存态，否则可能被稍后返回的旧存档覆盖掉。
    await _ready;

    final String digest = _digest(password);
    // 先落到内存再写存储：存储不可用时本次会话仍能正常上锁/解锁，
    // 只是重启后需要重新设置，比「点了保存却毫无反应」好。
    _hash = digest;
    _enabled = true;
    _failures = 0;
    _lockUntil = null;
    _lastError = null;
    try {
      await _write(keyHash, digest);
      await _write(keyEnabled, '1');
    } catch (_) {
      // 存储异常吞掉，见类文档第 3 条。
    }
    return null;
  }

  /// 清除密码（同时关掉所有自动锁定开关）。
  ///
  /// 关闭开关是官方语义的一部分：没有密码的开关毫无意义，
  /// 留着它们会让下次设置密码时「莫名其妙就又锁上了」。
  Future<void> clearPassword() async {
    await _ready;
    _hash = null;
    _enabled = false;
    _triggers.clear();
    _locked = false;
    _failures = 0;
    _lockUntil = null;
    _lastError = null;
    try {
      await _remove(keyHash);
      await _write(keyEnabled, '0');
      await _remove(keyTriggers);
    } catch (_) {
      // 同上：清不掉存储也不能让界面卡住。
    }
  }

  /// 用明文校验。成功则解锁并把失败计数清零。
  ///
  /// 没设密码时直接返回 true：没上锁的东西不该要求密码，否则用户会被
  /// 永久关在门外。冷却期内**即使密码正确也拒绝**——否则冷却形同摆设，
  /// 攻击者只要多试一次就能验证「猜对了没有」。
  Future<bool> verifyPassword(String password) async {
    await _ready;
    if (!hasPassword) {
      _locked = false;
      return true;
    }

    final int cooldown = cooldownRemainingMs;
    if (cooldown > 0) {
      _lastError = '尝试次数过多，请 ${_secondsOf(cooldown)} 秒后重试';
      return false;
    }

    if (_digest(password) == _hash) {
      _failures = 0;
      _lockUntil = null;
      _lastError = null;
      _locked = false;
      return true;
    }

    _failures++;
    if (_failures >= _maxAttempts) {
      _lockUntil = _now().add(_lockout);
      _failures = 0;
      _lastError = '尝试次数过多，请 ${_lockout.inSeconds} 秒后重试';
      return false;
    }
    _lastError = '密码错误，还可尝试 $attemptsLeft 次';
    return false;
  }

  /// 手动上锁（设备卡片上的「立即锁定」、返回主界面等）。
  ///
  /// 没密码时不上锁：那样的锁定态永远解不开（[verifyPassword] 虽然会放行，
  /// 但 UI 会白弹一个输入框）。
  void lock() {
    if (!hasPassword) return;
    _locked = true;
  }

  /// 静默解锁：远程协助结束、用户已完成密码/验证码校验后调用，不弹框。
  ///
  /// 与 [verifyPassword] 的区别是**不做任何校验**、也不动失败计数——
  /// 调用方已经拿到了别的凭据（短信码）或者场景本身就意味着「允许进入」。
  void unlockQuietly() {
    _locked = false;
  }

  /// 某个触发点是否该上锁（只有 [hasPassword] 且该开关打开才返回 true）。
  ///
  /// [AutoLockTrigger.duringAssist] 的语义是「协助期间保持锁定」，所以它
  /// **不主动上锁**（由调用方在协助开始时调 [lock]），这里只回答开关状态
  /// 供设置页展示；协助结束时调 [unlockQuietly]。
  bool shouldLock(AutoLockTrigger trigger) =>
      hasPassword && isTriggerEnabled(trigger);

  /// 单个自动锁定开关是否打开（无关于是否设了密码）。
  bool isTriggerEnabled(AutoLockTrigger trigger) => _triggers.contains(trigger);

  /// 改写某个自动锁定开关。
  ///
  /// 存储失败同样只吞掉：本次会话的设置立即生效，下次启动会回到存档值，
  /// 这比弹错误对话框打断用户操作更合适。
  Future<void> setTrigger(AutoLockTrigger trigger, bool enabled) async {
    await _ready;
    if (enabled) {
      _triggers.add(trigger);
    } else {
      _triggers.remove(trigger);
    }
    try {
      await _write(keyTriggers, _encodeTriggers());
    } catch (_) {
      // 见方法文档。
    }
  }

  /// 剩余冷却毫秒（0 表示可立即重试）。
  int get cooldownRemainingMs {
    final DateTime? until = _lockUntil;
    if (until == null) return 0;
    final int ms = until.difference(_now()).inMilliseconds;
    return ms > 0 ? ms : 0;
  }

  /// 最近一次失败原因（UI 提示用，未失败为 null）。
  String? get lastError => _lastError;

  /// 剩余可尝试次数（冷却期为 0）。
  int get attemptsLeft {
    if (cooldownRemainingMs > 0) return 0;
    final int left = _maxAttempts - _failures;
    return left > 0 ? left : 0;
  }

  /// 首次加载：读存档，任何异常都降级为「没设密码」。
  Future<void> _load() async {
    try {
      final String? digest = await _read(keyHash);
      final String? enabled = await _read(keyEnabled);
      final String? triggers = await _read(keyTriggers);

      _hash = (digest != null && digest.isNotEmpty) ? digest : null;
      _enabled = enabled == '1';
      if (triggers != null) {
        _triggers
          ..clear()
          ..addAll(
            triggers
                .split(',')
                .map(AutoLockTrigger.fromName)
                .whereType<AutoLockTrigger>(),
          );
      }
    } catch (_) {
      // 存档损坏/权限问题：当作没设密码，绝不能让启动崩在 [ready] 上。
      _hash = null;
      _enabled = false;
    }
  }

  /// 存档格式：`onClose,duringAssist`（按枚举声明顺序，避免 diff 抖动）。
  String _encodeTriggers() => AutoLockTrigger.values
      .where(_triggers.contains)
      .map((AutoLockTrigger trigger) => trigger.name)
      .join(',');

  /// 明文只在这里出现一次，绝不外流。
  static String _digest(String password) =>
      sha256.convert(utf8.encode(password)).toString();

  /// 字符类别数：数字 / 英文字母 / 其它各算一类。
  static int _characterClasses(String password) {
    bool hasDigit = false;
    bool hasLetter = false;
    bool hasOther = false;
    for (final int code in password.codeUnits) {
      if (code >= 0x30 && code <= 0x39) {
        hasDigit = true;
      } else if ((code >= 0x41 && code <= 0x5A) ||
          (code >= 0x61 && code <= 0x7A)) {
        hasLetter = true;
      } else {
        hasOther = true;
      }
    }
    return (hasDigit ? 1 : 0) + (hasLetter ? 1 : 0) + (hasOther ? 1 : 0);
  }

  /// 校验结果 → 中文文案（设置页输入框正下方的红字）。
  static String _verdictMessage(PasswordVerdict verdict) => switch (verdict) {
    PasswordVerdict.tooShort || PasswordVerdict.tooLong => '密码长度需 8-16 位',
    PasswordVerdict.tooWeak => '密码需包含字母和数字两类以上',
    PasswordVerdict.ok => '',
  };

  /// 毫秒向上取整成秒：只剩 300ms 时提示「1 秒」而不是「0 秒」。
  static int _secondsOf(int milliseconds) => (milliseconds + 999) ~/ 1000;
}

/// 短信验证码倒计时（官方 60s 重发）。
///
/// 为什么自带倒计时而不是靠 `Timer.periodic`：计时器只是「驱动重绘」的工具，
/// 真正的剩余时间必须由注入的 [now] 推算，否则应用切后台被挂起后
/// 计时器停了、剩余秒数就永远停在 60。UI 侧可以每 100ms 轮询一次
/// [remainingSeconds] 或者用 Timer 只负责 setState。
class SmsCodeTimer {
  SmsCodeTimer({
    DateTime Function()? now,
    Duration interval = const Duration(seconds: 60),
  }) : _now = now ?? DateTime.now,
       // 同上：私有字段不能用初始化形参。
       // ignore: prefer_initializing_formals
       _interval = interval;

  final DateTime Function() _now;

  /// 重发间隔（官方 60s）。
  final Duration _interval;

  /// 本次发送的起点（null = 还没发过/已重置）。
  DateTime? _startedAt;

  /// 触发「获取验证码」。冷却中返回 false（不得重复发）。
  bool start() {
    if (!canResend) return false;
    _startedAt = _now();
    return true;
  }

  /// 剩余秒数，按 [now] 计算并夹到 `0..interval`。
  ///
  /// 夹上界是为了防「系统时间被往回调」时显示成 75 秒这种怪数字。
  int get remainingSeconds {
    final DateTime? startedAt = _startedAt;
    if (startedAt == null) return 0;
    final int remain =
        _interval.inSeconds - _now().difference(startedAt).inSeconds;
    if (remain < 0) return 0;
    if (remain > _interval.inSeconds) return _interval.inSeconds;
    return remain;
  }

  /// 是否可以重新发送。
  bool get canResend => remainingSeconds == 0;

  /// 清空倒计时（验证码校验通过、切换解锁方式时调用，回到可发送状态）。
  void reset() {
    _startedAt = null;
  }
}
