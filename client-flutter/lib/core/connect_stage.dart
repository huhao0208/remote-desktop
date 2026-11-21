/// 连接阶段：把「加入房间 → 等 hello → 协商 → 首帧」拆成 7 步，对齐官方等待页。
///
/// 为什么要枚举而不是在页面里写一堆布尔：等待期最长可达十几秒，用户需要知道
/// **卡在哪一步**（是服务端分配房间慢，还是被控端没回 hello，还是 WebRTC 协商失败）。
/// 枚举的序号即时间顺序，[ConnectProgress.ratio] 直接按序号线性映射，页面不用自己算。
enum ConnectStage {
  init('正在连接服务器', '正在建立与远控服务端的连接'),
  buildServer('正在创建连接通道', '正在分配房间与信令地址'),
  syncInfo('正在同步设备信息', '正在读取被控端设备信息'),
  setting('正在应用串流设置', '正在下发画质与帧率，等待被控端回执'),
  optimized('正在优化传输链路', '正在协商 WebRTC 通道，JPEG 兜底会跳过这一步'),
  transmitting('正在传输画面', '已开始推流，等待第一帧画面'),
  success('连接成功', '画面已就绪'),
  failed('连接失败', '点右上角重连，或检查服务端地址');

  const ConnectStage(this.label, this.hint);

  /// 阶段名（等待页第一行），如「正在连接服务器」。
  final String label;

  /// 第二行细节文案，说明这一步在等什么。
  final String hint;

  /// 是否还在进行中：`success` / `failed` 之外都算忙（页面据此决定转不转圈）。
  bool get isBusy => this != ConnectStage.success && this != ConnectStage.failed;

  /// 是否已经出画面：只有 `success` 为 true。
  bool get isReady => this == ConnectStage.success;
}

/// 一次连接尝试的推进状态机。
///
/// 只前进不后退的原因：信令是异步的，`stream.config.ack` 可能比 `agent.hello`
/// 先到（服务端补发、重连残留），若允许后退，UI 会被迟到事件拽回「同步设备信息」，
/// 看起来像卡住重来。这里的策略是「见过的阶段就不退」，直到 [reset]。
class ConnectProgress {
  ConnectProgress();

  /// 已到达的最远阶段序号（`failed` 不参与，失败时保留失败前的值供进度条用）。
  int _furthest = 0;

  ConnectStage _stage = ConnectStage.init;

  String? _failure;

  /// 除 `failed` 之外的可达阶段数量（init..success 共 7 个）。
  static const int _stepCount = 7;

  ConnectStage get stage => _stage;

  /// 失败原因（仅 failed 阶段非空）。
  String? get failure => _failure;

  /// 推进到某阶段：只允许前进，同值或后退忽略（避免乱序事件把 UI 拽回去）。
  ///
  /// `failed` 一律拒绝——失败必须走 [fail]，否则进度条会跳到一个没有含义的位置。
  /// 已经失败后也不再接受推进，必须 [reset] 后重新来过，避免旧会话事件“复活”UI。
  void go(ConnectStage next) {
    if (next == ConnectStage.failed) return;
    if (_stage == ConnectStage.failed) return;
    // 注意用 `<=`：同阶段重复调用也要幂等，ratio 不能被再算一次（虽然值一样，
    // 但语义上「没有推进」就不该动状态）。
    if (next.index <= _furthest) return;
    _furthest = next.index;
    _stage = next;
    // 只有真正前进时才清 failure：理论上 failed 后已不再接受 go，这里是兜底。
    _failure = null;
  }

  /// 记录失败并落到 failed 阶段。
  ///
  /// 进度条停在失败前那一刻的比例——回零会让用户以为「又要从第一步重来」，
  /// 保留比例才能看出是在哪一步断的。
  void fail(String reason) {
    final String text = reason.trim();
    _stage = ConnectStage.failed;
    _failure = text.isEmpty ? '连接中断，请点重连重试' : text;
  }

  /// 重连时归零到 init。
  void reset() {
    _furthest = 0;
    _stage = ConnectStage.init;
    _failure = null;
  }

  /// 进度 0.0–1.0，供进度条用（failed 保持失败前的比例）。
  double get ratio => _furthest / (_stepCount - 1);
}
