/// 控制端麦克风（协议 v3 §6）的纯状态逻辑。
///
/// 单独抽出来的理由和 `mouse_mode.dart` / `key_mapping.dart` 一样：页面里那坨
/// `setState` 无法单测，而这里的三条约束（pending 防连点、超时回弹、只认回执）
/// 恰恰是最容易写错、写错了用户就直接骂「点了没用」的地方。
///
/// 核心不变式：**UI 显示的开关态永远由 `mic.state` 回执决定，不由点击决定**。
/// 点击只把 [MicSwitch] 推进到 `pending`，3 秒没回执就弹回原位。
library;

/// 麦克风开关的对外状态。
enum MicState {
  /// 关闭（确定态）。
  off,

  /// 已点击、等被控端回执。UI 应显示为「切换中」，禁止再点。
  pendingOn,

  /// 开启（确定态，被控端确认真的在放音）。
  on,

  /// 已点击关闭、等回执。
  pendingOff,

  /// 不可用（被控端不支持 / 没有音频通路）。UI 置灰并说明原因。
  unavailable,
}

/// 失败原因码（协议 v3 §6.2 的 `err` 字段）。
enum MicError {
  /// 拿不到本地麦克风（用户拒权 / 没有设备）。
  noTrack,

  /// 被控端没有可用的放音能力。
  noAudio,

  /// 被控端正忙（另一个控制端正在喊话）。
  busy,

  /// 通路不支持（JPEG 通路没有 RTP）。
  unsupported,

  /// 3 秒内没收到回执。
  timeout,

  unknown,
}

/// 错误码 → 中文说明。空串表示「没有错误」。
String describeMicError(MicError? err) => switch (err) {
      null => '',
      MicError.noTrack => '无法使用本机麦克风，请检查系统权限',
      MicError.noAudio => '被控端没有可用的扬声器',
      MicError.busy => '被控端正在被其他人喊话',
      MicError.unsupported => '当前通路不支持语音（画面为 JPEG 兜底时不可用）',
      MicError.timeout => '被控端没有响应，请稍后重试',
      MicError.unknown => '语音开关失败',
    };

/// 从协议 `err` 字符串解析。
MicError parseMicError(Object? raw) {
  final String s = (raw ?? '').toString().trim().toLowerCase();
  return switch (s) {
    '' => MicError.unknown,
    'no_track' || 'notrack' || 'no_mic' => MicError.noTrack,
    'no_audio' || 'noaudio' => MicError.noAudio,
    'busy' => MicError.busy,
    'unsupported' => MicError.unsupported,
    'timeout' => MicError.timeout,
    _ => MicError.unknown,
  };
}

/// 麦克风开关状态机。**纯逻辑、无 IO**，页面负责在正确的时机调 `on*` 方法。
///
/// 用法：
/// ```dart
/// final MicSwitch mic = MicSwitch(supported: hello.mic);
/// // 用户点击
/// final bool wantOn = mic.nextIntent;         // 该开还是该关
/// if (wantOn) { acquireTrack().then((ok) => ok ? mic.markOnRequested() : mic.fail(noTrack)); }
/// // 收到回执
/// mic.confirm(on: true, ok: true, err: null);
/// // 3 秒定时器
/// if (mic.expire()) toast(describeMicError(mic.error));
/// ```
class MicSwitch {
  MicSwitch({bool supported = false}) : _state = supported ? MicState.off : MicState.unavailable;

  MicState _state;
  MicError? _error;

  MicState get state => _state;

  MicError? get error => _error;

  /// 是否确定处于开启态（只有这个为真时才该在界面上显示「正在喊话」）。
  bool get isOn => _state == MicState.on;

  /// 是否在等回执。
  bool get isPending => _state == MicState.pendingOn || _state == MicState.pendingOff;

  bool get available => _state != MicState.unavailable;

  /// 点击开关时「下一步应该是开还是关」。
  ///
  /// pending 期间返回当前确定态的方向（即「还是原来的」，让调用方直接忽略本次点击）；
  /// 调用前先看 [canToggle] 更省事。
  bool get nextIntent => _state == MicState.on;

  /// pending 或不可用时不允许再点——连点会产生一串 `mic` 消息，
  /// Agent 侧会互相打架，最后状态取决于到达顺序，不可预测。
  bool get canToggle => available && !isPending;

  /// 被控端能力变化（重连拿到新 hello）时调用。
  ///
  /// 能力从有到无要强制归位到 unavailable 并清错误；从无到有则回到 off。
  /// **不保留上次开关态**：协议 §6.6 要求重连后麦克风是 OFF。
  void setSupported(bool supported) {
    if (supported) {
      if (_state == MicState.unavailable) {
        _state = MicState.off;
        _error = null;
      }
      return;
    }
    _state = MicState.unavailable;
    _error = null;
  }

  /// 用户点了开麦，且本地已成功拿到音轨 → 进入等回执。
  void markOnRequested() {
    if (_state == MicState.unavailable) return;
    _state = MicState.pendingOn;
    _error = null;
  }

  /// 用户点了关麦 → 进入等回执。
  void markOffRequested() {
    if (_state == MicState.unavailable) return;
    _state = MicState.pendingOff;
    _error = null;
  }

  /// 收到 `mic.state` 回执。
  ///
  /// 返回 true 表示状态确实变了（调用方据此决定要不要 `setState` + 启停音轨）。
  ///
  /// 注意 `on` 取的是**回执里的实际状态**，不是用户意图：Agent 可能因为
  /// `busy` 拒绝开启，此时 `ok:false` + `on:false`，必须回到 off 而不是停在 pending。
  bool confirm({required bool on, required bool ok, Object? err}) {
    final MicState before = _state;
    if (!ok || (on && _state == MicState.unavailable)) {
      _state = _state == MicState.unavailable ? MicState.unavailable : MicState.off;
      _error = ok ? null : parseMicError(err);
      return before != _state || _error != null;
    }
    _state = on ? MicState.on : MicState.off;
    _error = null;
    return before != _state;
  }

  /// 本地失败（拿不到音轨等）→ 直接回 off 并记原因。
  void fail(MicError err) {
    _state = _state == MicState.unavailable ? MicState.unavailable : MicState.off;
    _error = err;
  }

  /// pending 超时。仍在 pending 时返回 true 并弹回 off，否则返回 false（迟到回执不算超时）。
  bool expire() {
    if (!isPending) return false;
    _state = MicState.off;
    _error = MicError.timeout;
    return true;
  }

  /// 断链 / 页面退出 → 强制归位。**不记忆上次状态**（协议 §6.6）。
  void reset() {
    _state = _state == MicState.unavailable ? MicState.unavailable : MicState.off;
    _error = null;
  }
}