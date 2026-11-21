/// 鼠标三模式的纯逻辑层：模式语义 / 参数存档 / 相对位移累加 / 智能切态。
///
/// 为什么不写进远控页：`RemotePage` 里塞这套规则就得跟着 widget 生命周期跑，
/// 滞回计时、边界裁剪这类「时间与状态」逻辑一旦掺进 setState 就没法单测，
/// 而这恰恰是最容易出「鼠标抖一下跳一下」的地方。这里只用 `dart:core`，
/// 无 IO、无 Flutter 依赖，页面只负责把 RTT/拖拽状态喂进来。
library;

/// 三种鼠标模式（对齐协议 v3 §3 表格与官方 `ControlledMouse/ControlMouse/AutoMouse`）。
enum MouseMode {
  /// 绝对坐标 `input.move`，被控端系统光标可见。默认态，兼容性最好。
  remote,

  /// 相对位移 `input.moverel`，被控端光标隐藏，控制端用本机光标指示位置。
  control,

  /// 由 [AutoMousePolicy] 在 remote/control 之间自动切。
  auto,
}

extension MouseModeInfo on MouseMode {
  /// 设置页/工具栏上的中文名。
  String get label {
    switch (this) {
      case MouseMode.remote:
        return '使用被控端鼠标';
      case MouseMode.control:
        return '使用主控端鼠标';
      case MouseMode.auto:
        return '智能鼠标';
    }
  }

  /// 一句话说明，口径取协议 §3 表格的「行为」列。
  ///
  /// 不写「低延迟更流畅」这类空话：用户选模式时真正要知道的是
  /// **光标在谁那边、发的是绝对坐标还是相对位移**。
  String get hint {
    switch (this) {
      case MouseMode.remote:
        return '发送绝对坐标，被控端光标可见，兼容性最好';
      case MouseMode.control:
        return '发送相对位移，隐藏被控端光标，用本机光标指示位置';
      case MouseMode.auto:
        return '延迟高于 60ms 或正在拖拽时自动切到主控端鼠标，停止后 2 秒恢复';
    }
  }

  /// 该模式是否直接决定发 `moverel`。
  ///
  /// `auto` 为 false：它最终发什么由 [AutoMousePolicy] 的运行态决定，
  /// 这里返回 true 会让页面误以为静态下了结论。
  bool get sendsRelativeMove => this == MouseMode.control;

  /// 该模式是否直接决定隐藏被控端光标。
  ///
  /// 与 [sendsRelativeMove] 分开：`cursor` 指令和 `moverel` 是两条独立报文，
  /// 页面要在「切回 remote 立刻发 cursor:visible:true」时单独看这一位。
  bool get hidesRemoteCursor => this == MouseMode.control;
}

/// 鼠标参数存档。不可变值 + [copyWith]，与 `ViewTransform` 同一风格。
class MouseSettings {
  const MouseSettings({
    this.mode = MouseMode.remote,
    this.gameMode = false,
    this.speed = 1.0,
  });

  /// 默认 [MouseMode.remote]：绝对坐标不依赖 Agent 的 warp 实现，老版本也能用。
  final MouseMode mode;

  /// 游戏鼠标模式：只在相对位移下有意义（再乘 [speed]，不做平滑/加速曲线）。
  final bool gameMode;

  /// 相对位移倍率。构造时不夹取（const 构造器做不到），
  /// 由 [effectiveSpeed] 在取值时统一钳制，避免两处规则不一致。
  final double speed;

  static const double minSpeed = 0.5;
  static const double maxSpeed = 3.0;

  /// 实际生效的倍率：非游戏模式恒为 1.0。
  ///
  /// 为什么这里再钳一次而不是信任 [speed]：手改配置文件、旧版本落盘的 5.0
  /// 都会绕过 UI 滑块，一旦乘进位移就是「鼠标飞出去」，钳制必须发生在
  /// 唯一的使用点上。
  double get effectiveSpeed {
    if (!gameMode) return 1.0;
    final double raw = speed.isFinite ? speed : 1.0;
    return raw.clamp(minSpeed, maxSpeed).toDouble();
  }

  MouseSettings copyWith({MouseMode? mode, bool? gameMode, double? speed}) =>
      MouseSettings(
        mode: mode ?? this.mode,
        gameMode: gameMode ?? this.gameMode,
        speed: speed ?? this.speed,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'mode': mode.name,
    'gameMode': gameMode,
    'speed': speed,
  };

  /// 容错解析：缺字段/类型错一律退默认，[speed] 越界钳到 0.5–3.0。
  ///
  /// 冷启动时这份 JSON 可能来自旧版本或被用户手改过，抛异常会让整个
  /// 设置页白屏——宁可悄悄用默认值。
  factory MouseSettings.fromJson(Map<String, dynamic> json) {
    final Object? rawMode = json['mode'];
    MouseMode mode = MouseMode.remote;
    if (rawMode is String) {
      for (final MouseMode m in MouseMode.values) {
        if (m.name == rawMode) {
          mode = m;
          break;
        }
      }
    }

    final Object? rawGame = json['gameMode'];
    final bool gameMode = rawGame is bool ? rawGame : false;

    double speed = 1.0;
    final Object? rawSpeed = json['speed'];
    // 只认 num：字符串 "abc" 是脏数据，宁可回默认也不去 tryParse
    if (rawSpeed is num && rawSpeed.isFinite) {
      speed = rawSpeed.toDouble().clamp(minSpeed, maxSpeed).toDouble();
    }

    return MouseSettings(mode: mode, gameMode: gameMode, speed: speed);
  }

  @override
  String toString() =>
      'MouseSettings(mode: ${mode.name}, gameMode: $gameMode, speed: $speed)';
}

/// 相对位移的本地光标累加器（主控端鼠标模式）。
///
/// 屏幕上看的是**本机**光标，但被控端需要的是「相对位移了多少比例的屏幕」，
/// 而本机光标在缩放、多屏、贴边时会被系统接管，所以位置必须自己记一份：
/// 一旦撞到 [0,1] 边界，越界那部分位移不能再发出去——否则远端光标会先撞墙
/// 再「粘住」，而控制端挪回来时远端却不跟手，两边彻底错位。
class RelativeCursor {
  RelativeCursor({double x = 0.5, double y = 0.5})
    : _x = x.clamp(0.0, 1.0).toDouble(),
      _y = y.clamp(0.0, 1.0).toDouble();

  /// 边界判定容差：浮点累加出来的 0.9999999 其实已经在墙上。
  static const double _edgeEpsilon = 1e-9;

  double _x;
  double _y;

  /// 归一化横坐标（0..1）。
  double get x => _x;

  /// 归一化纵坐标（0..1）。
  double get y => _y;

  /// 是否贴到了任意一条边（此时那个方向再推也不会产生位移）。
  bool get atEdge =>
      _x <= _edgeEpsilon ||
      _x >= 1.0 - _edgeEpsilon ||
      _y <= _edgeEpsilon ||
      _y >= 1.0 - _edgeEpsilon;

  /// 施加一个归一化位移，返回**实际生效的**位移（撞边界时被裁掉）。
  ///
  /// 返回值而非只改内部状态，是因为调用方要把它原样塞进 `input.moverel`；
  /// 若发出去的是请求值，远端算出的位置就会和这里记的对不上。
  /// [speed] 只在游戏模式（相对位移）下传，其余情况保持 1.0。
  ({double dx, double dy}) moveBy(double dx, double dy, {double speed = 1.0}) {
    // 非有限值/非正值会让光标瞬移或反向，按 1.0 处理（与 MouseSettings 同口径）
    final double k = speed.isFinite && speed > 0 ? speed : 1.0;
    final double wantX = dx * k;
    final double wantY = dy * k;
    // 非有限输入直接吞掉：NaN 一旦混进坐标，后续所有 clamp 都救不回来
    if (!wantX.isFinite || !wantY.isFinite) {
      return (dx: 0.0, dy: 0.0);
    }
    final double nextX = (_x + wantX).clamp(0.0, 1.0).toDouble();
    final double nextY = (_y + wantY).clamp(0.0, 1.0).toDouble();
    final double appliedX = nextX - _x;
    final double appliedY = nextY - _y;
    _x = nextX;
    _y = nextY;
    return (dx: appliedX, dy: appliedY);
  }

  /// 回到指定位置（默认屏幕中心）。
  ///
  /// 切换模式/重连后必须复位：残留的旧位置会让第一下拖拽从「上次停的地方」
  /// 继续累加，而远端光标已经回到中心，两边立刻错位。
  void reset({double x = 0.5, double y = 0.5}) {
    _x = x.clamp(0.0, 1.0).toDouble();
    _y = y.clamp(0.0, 1.0).toDouble();
  }

  @override
  String toString() => 'RelativeCursor(x: $_x, y: $_y)';
}

/// 智能鼠标：按 RTT 与拖拽状态在 remote/control 之间选，带滞回。
///
/// 为什么要滞回：RTT 是滑动平均，在 60ms 阈值附近会来回摆。没有滞回时
/// 一次抖动就让远端光标隐藏又出现，视觉上像「闪屏」；用户最先投诉的
/// 往往就是这种「我也没动，它自己在那跳」。
class AutoMousePolicy {
  AutoMousePolicy({
    this.highLatencyMs = 60,
    this.recoverAfter = const Duration(seconds: 2),
  });

  /// 高延迟阈值（协议 §3：RTT 平滑值 > 60ms 切 control）。
  final double highLatencyMs;

  /// 切到 control 后至少维持多久才允许回 remote。
  final Duration recoverAfter;

  MouseMode _current = MouseMode.remote;

  /// 当前实际生效模式（[MouseMode.auto] 不会出现在这里）。
  MouseMode get current => _current;

  /// 计算本帧应使用的模式。
  ///
  /// [since] 是「距上次切到 control 已经过了多久」，由调用方用真实时钟测量
  /// ——本层不碰 `DateTime.now()`，否则单测就得靠 sleep，既慢又不稳。
  ///
  /// 优先级：拖拽 > 高延迟 > 滞回 > 默认 remote。
  /// 拖拽排第一是因为拖拽中切模式会直接导致「拖到一半指针跑了」，
  /// 宁可多等一会儿也不要中途换靶。
  MouseMode decide({
    required double rttMs,
    required bool dragging,
    required Duration since,
  }) {
    // rttMs <= 0 / NaN 表示还没采样（刚连上第一帧）：当作「未知」，
    // 不能因为「没数据」就判成高延迟，否则一连上就闪进 control。
    final bool sampled = rttMs.isFinite && rttMs > 0;
    final bool slow = sampled && rttMs > highLatencyMs;

    if (dragging || slow) {
      _current = MouseMode.control;
      return _current;
    }

    if (_current == MouseMode.control && since < recoverAfter) {
      // 滞回窗口内即使 RTT 已恢复也留在 control：避免阈值附近来回抖
      return _current;
    }

    _current = MouseMode.remote;
    return _current;
  }

  /// 回到默认态（退出远控/重连时调用，避免把上一条连接的状态带进新会话）。
  void reset() {
    _current = MouseMode.remote;
  }
}
