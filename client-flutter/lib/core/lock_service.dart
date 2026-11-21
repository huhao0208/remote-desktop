import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';

import 'client_lock.dart';

/// 客户端锁的全局入口（官方 B6.3）。
///
/// 为什么要有这一层：`ClientLock` 是纯逻辑，`isLocked` 只是普通字段；
/// UI 需要「锁上/解开」时自动刷新，所以在这里补一个 [ValueNotifier]。
/// 同时把 SharedPreferences 的读写接进去——`client_lock.dart` 本身
/// 不依赖任何存储，单测才能毫秒级跑完。
class LockService {
  LockService._();

  static final LockService instance = LockService._();

  final ClientLock client = ClientLock(
    read: (String key) async =>
        (await SharedPreferences.getInstance()).getString(key),
    write: (String key, String value) async =>
        (await SharedPreferences.getInstance()).setString(key, value),
    remove: (String key) async =>
        (await SharedPreferences.getInstance()).remove(key),
  );

  /// 是否处于锁定态。UI 用 `ValueListenableBuilder` 监听它。
  final ValueNotifier<bool> locked = ValueNotifier<bool>(false);

  /// 启动时调用：等配置加载完，再按 `onStart` 策略决定要不要立刻锁。
  ///
  /// 必须在 `runApp` 之前 await：否则首帧会先渲染出设备列表再被锁屏盖住，
  /// 用户能看到一闪而过的主界面（隐私问题，不只是难看）。
  Future<void> init() async {
    await client.ready;
    if (client.shouldLock(AutoLockTrigger.onStart)) {
      client.lock();
    }
    locked.value = client.isLocked;
  }

  /// 用密码解锁。失败时 [ClientLock.lastError] 里有原因，UI 直接展示。
  Future<bool> unlock(String password) async {
    final bool ok = await client.verifyPassword(password);
    locked.value = client.isLocked;
    return ok;
  }

  /// 手动上锁。
  void lock() {
    if (!client.hasPassword) return;
    client.lock();
    locked.value = true;
  }

  /// 静默解锁：远程协助结束、密码验证完成后调用。
  void unlockQuietly() {
    client.unlockQuietly();
    locked.value = false;
  }

  /// 「远程协助本设备期间自动锁定」——被控会话开始时调。
  ///
  /// 注意配套：会话结束必须调 [unlockQuietly]，否则用户被永久锁在应用外。
  void onAssistStarted() {
    if (client.shouldLock(AutoLockTrigger.duringAssist)) lock();
  }

  void onAssistEnded() {
    if (locked.value && client.isTriggerEnabled(AutoLockTrigger.duringAssist)) {
      unlockQuietly();
    }
  }
}
