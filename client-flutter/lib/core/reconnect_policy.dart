/// 远控会话的自动重连退避策略（对齐 UU 远程「指数退避 + restoreConnect」）。
///
/// 为什么单独抽一层：页面里只有「重新连接」按钮时，信令断开或首帧久等**只能靠人手**，
/// 弱网里用户要反复点。把「等多久、还剩几次、何时放弃」收敛成纯状态机，
/// 页面只管 `await Future.delayed(policy.next()!)` 再调 restore，倒计时文案也直接取 [label]。
///
/// 设计取舍：
/// - **封顶不回落**：前几拍指数增长（1/2/4/8/15/30），到最后一档就停在 30 秒。
///   被控端重启、路由切换通常十几秒内恢复，长尾再退到 60/120 秒只会让用户觉得「卡死了」。
/// - **有上限**：`maxAttempts` 次后停手，避免代理挂掉时客户端无限重连、把日志和设备列表刷爆，
///   同时把控制权交回用户（[exhausted] 为 true 时页面应亮出「手动重连」）。
/// - **纯逻辑**：只依赖 `dart:core`，不碰 Flutter/Timer，单测毫秒级跑完，也不用 mock 时钟。
class ReconnectPolicy {
  /// [delays] 为各次尝试的等待时长，最后一项即封顶值；[maxAttempts] 为自动重连总次数上限。
  ///
  /// 入参列表会复制一份（[List.unmodifiable]）：调用方常把全局常量表传进来，
  /// 若之后被就地修改，正在跑的策略会突然改节奏，排查起来极其痛苦。
  ReconnectPolicy({
    List<Duration> delays = const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 15),
      Duration(seconds: 30),
    ],
    this.maxAttempts = 8,
  }) : delays = List<Duration>.unmodifiable(delays);

  /// 各档等待时长（只读副本）。
  final List<Duration> delays;

  /// 自动重连次数上限；`<= 0` 表示一上线就是「已放弃」，不抛异常。
  final int maxAttempts;

  /// 已经排过几次自动重连（reset 后归零）。
  int get attempts => _attempts;

  int _attempts = 0;

  /// 是否已放弃自动重试（需人工介入）。
  ///
  /// 空 [delays] 也算耗尽：没有可等的时长，重连就没有意义，不如直接提示用户手动处理。
  bool get exhausted => _attempts >= maxAttempts || delays.isEmpty;

  /// 取下一拍等待时长并自增；已耗尽返回 null。
  ///
  /// 返回 null 是**终态**，只有 [reset] 能再放行，避免调用方在定时器回调里反复拿到时长、
  /// 无限重连。
  Duration? next() {
    if (exhausted) return null;
    final Duration delay = _delayAt(_attempts);
    _attempts++;
    return delay;
  }

  /// 连接成功或用户手动重连时归零。
  ///
  /// 主控务必在「收到首帧 / onConnected」时调用：否则下一次故障会直接从 30 秒起步，
  /// 用户会以为客户端坏了。
  void reset() {
    _attempts = 0;
  }

  /// 不消费计数的「下一次会等多久」（给 UI 预告文案用）。
  Duration? get pendingDelay => exhausted ? null : _delayAt(_attempts);

  /// 给 UI 的一行文案，如「第 3 次自动重连（4 秒后）」/「自动重连已停止，请手动重连」。
  ///
  /// 编号取**即将发生**的那一次（`attempts + 1`），与 [pendingDelay] 一一对应；
  /// 还没重连过时不写「第 1 次」，免得用户误以为已经失败了一轮。
  String get label {
    if (exhausted) return '自动重连已停止，请手动重连';
    final int seconds = _delayAt(_attempts).inSeconds;
    if (_attempts == 0) return '断线后 $seconds 秒开始自动重连';
    return '第 ${_attempts + 1} 次自动重连（$seconds 秒后）';
  }

  /// 按下标取档位，超出序列长度就钉在最后一档（封顶不回落）。
  Duration _delayAt(int index) {
    final int safe = index < delays.length ? index : delays.length - 1;
    return delays[safe];
  }
}
