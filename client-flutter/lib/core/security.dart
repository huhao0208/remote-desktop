import 'models.dart';

/// 防窥四档，键名与官方 `Control.Privacy.*` 一致。
///
/// `screenoff` 与 `wallpaper` 在部分平台不可用：被控端在 `hello.privacy_engine`
/// 里报自己用的是哪种引擎（`overlay` / `unsupported`），面板据此置灰，
/// 而不是让用户点了没反应。
enum PrivacyMode {
  off('off', '不启用', '被控端屏幕未防护，旁人可见'),
  blank('blank', '黑屏防护', '在被控端显示屏上显示黑屏画面，遮挡屏幕内容'),
  screenoff('screenoff', '关闭显示屏', '被控端屏幕已熄屏，彻底防护隐私'),
  wallpaper('wallpaper', '隐私屏保', '被控端屏幕已防护，遮挡屏幕内容');

  const PrivacyMode(this.key, this.label, this.hint);

  final String key;
  final String label;
  final String hint;

  static PrivacyMode fromKey(String? key) {
    for (final PrivacyMode m in values) {
      if (m.key == key) return m;
    }
    return PrivacyMode.off;
  }
}

/// 电源动作，键名与官方 `ACTION_TYPE_*` 对齐。
enum PowerAction {
  lock('lock', '锁屏', '立即锁定被控端'),
  reboot('reboot', '重启', '倒计时结束后重启'),
  shutdown('shutdown', '关机', '倒计时结束后关机'),
  taskmgr('taskmgr', '任务管理器', '在被控端打开任务管理器');

  const PowerAction(this.key, this.label, this.hint);

  final String key;
  final String label;
  final String hint;

  static PowerAction? fromKey(String? key) {
    for (final PowerAction a in values) {
      if (a.key == key) return a;
    }
    return null;
  }

  /// 关机/重启要给用户撤销窗口，锁屏和任务管理器不需要。
  bool get needsCountdown => this == reboot || this == shutdown;
}

/// 被控端安全面板状态（`security.state` / `privacy.state` 合并后的视图）。
class SecurityState {
  const SecurityState({
    this.autoLock = false,
    this.muted = false,
    this.privacy = PrivacyMode.off,
    this.engine = 'unknown',
    this.error,
  });

  final bool autoLock;
  final bool muted;
  final PrivacyMode privacy;

  /// `overlay` = 真遮罩窗；`unsupported` = 当前平台做不了。
  final String engine;

  /// 最近一次操作的错误（面板顶部红字，成功就清空）。
  final String? error;

  bool get privacySupported => engine == 'overlay';

  /// 官方 `statusTitle`：已防护 / 需关注。
  bool get protectedNow => privacy != PrivacyMode.off || autoLock;

  SecurityState copyWith({
    bool? autoLock,
    bool? muted,
    PrivacyMode? privacy,
    String? engine,
    String? error,
    bool clearError = false,
  }) =>
      SecurityState(
        autoLock: autoLock ?? this.autoLock,
        muted: muted ?? this.muted,
        privacy: privacy ?? this.privacy,
        engine: engine ?? this.engine,
        error: clearError ? null : (error ?? this.error),
      );

  factory SecurityState.fromHello(AgentHello hello) => SecurityState(
        autoLock: hello.autoLock,
        privacy: PrivacyMode.fromKey(hello.privacy),
        engine: hello.privacyEngine,
      );
}

/// 关机/重启倒计时（`power.state` 的 `pending/executing/cancelled`）。
class PowerCountdown {
  const PowerCountdown({required this.action, required this.remain});

  final PowerAction action;
  final int remain;
}
