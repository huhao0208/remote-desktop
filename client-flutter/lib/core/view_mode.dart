import 'dart:ui';

/// 控制端三态：操控 / 观看 / 观看+批注。
///
/// 为什么批注不单独占一个枚举值：官方工具栏里「批注」是观看态下的**开关**
/// （`viewModeToggleAnnotation`），关掉批注必须回到「观看」而不是「操控」。
/// 若把批注与观看并列为兄弟状态，关开关时就得记一个「上一个状态」，
/// 一旦状态机有一条边漏了就会串味；做成子态后所有转移都只依赖当前值。
enum ViewState {
  /// 操控：输入直达被控端。
  control,

  /// 观看：输入被拦截，可拖拽浏览。
  view,

  /// 观看 + 批注：手势画在叠加层上，仍然不发输入事件。
  annotation,
}

extension ViewStateX on ViewState {
  /// 是否拦截输入（true 时不发 input 事件给被控端）。
  ///
  /// 之所以收在这里而不是页面里写 `state != control`：手势层、鼠标层、
  /// 键盘层三处都要判断，散着写迟早有一处漏掉——用户在观看态点一下，
  /// 被控端就跟着动了，这是最容易被投诉的一类 bug。
  bool get interceptsInput => this != ViewState.control;

  /// 工具栏/状态条上的中文名。
  String get label {
    switch (this) {
      case ViewState.control:
        return '操控';
      case ViewState.view:
        return '观看';
      case ViewState.annotation:
        return '批注';
    }
  }
}

/// 缩放与平移。`scale == 1.0` 且 `offset == Offset.zero` 表示铺满视口的原始状态。
///
/// 为什么不直接把 `InteractiveViewer` 挂上去：远控画面是自绘的（解码纹理 +
/// CustomPaint 批注层），需要拿到「归一化坐标」反算坐标给被控端，且必须能
/// 精确限制在 [minScale]–[maxScale]；自己算这几个公式反而更可控，也方便单测。
class ViewTransform {
  const ViewTransform({this.scale = 1.0, this.offset = Offset.zero});

  /// 最小缩放：低于 1 只用于「缩小看全局」，再小画面就糊成马赛克。
  static const double minScale = 0.5;

  /// 最大缩放：4 倍足够看清 4K 画面里的小字，再大就是纯像素放大，没有信息量。
  static const double maxScale = 4.0;

  final double scale;
  final Offset offset;

  /// 是否处于原始状态（没有任何缩放/平移）。
  bool get isIdentity => scale == 1.0 && offset == Offset.zero;

  /// 以 [focal]（视口坐标）为锚点缩放：该点在屏幕上保持不动。
  ///
  /// 公式推导：内容点 `p` 满足 `focal = offset + p * scale`，若希望缩放后
  /// `p` 仍落在 `focal`，则 `focal = offset' + p * newScale`，两式相消得
  /// `offset' = focal - (focal - offset) * (newScale / scale)`。
  /// 用**夹取后**的倍率算偏移：factor 再大也只会到 [maxScale]，
  /// 若仍按原始 factor 算位置，画面会被甩出视口（滚轮连滚时最明显）。
  ViewTransform zoomAt({
    required Offset focal,
    required double factor,
    required Size viewport,
  }) {
    // factor 非正或非有限（NaN/Inf）会算出无意义的值，直接原样返回，不抛异常。
    if (!factor.isFinite || factor <= 0 || scale <= 0) return this;
    final double next = (scale * factor).clamp(minScale, maxScale).toDouble();
    final double ratio = next / scale;
    final Offset raw = focal - (focal - offset) * ratio;
    // 缩小到 1.0 以下时必须把 offset 收回 0，否则「缩回原尺寸但画面偏着」，
    // 用户还得手动拖回去——这是很多人吐槽的交互瑕疵。
    return ViewTransform(scale: next, offset: _clampFor(next, raw, viewport));
  }

  /// 平移。会夹取，保证画面不会被推出视口（推出去就只剩背景色，等于白屏）。
  ViewTransform pan(Offset delta, Size viewport) =>
      ViewTransform(scale: scale, offset: _clampFor(scale, offset + delta, viewport));

  /// 回到 1.0 / 0（适应视口）。
  ///
  /// 这里不做「按画面宽高比 fit」：那需要知道被控端源分辨率，属于解码层的知识，
  /// 且 fitScale 通常 < 1，会和 [minScale] 的语义打架。需要 fit 的调用方
  /// 自己算好 scale 后走 [copyWith]。
  ViewTransform reset() => const ViewTransform();

  /// 把「视口上的一次拖拽位移」换算成被控端归一化坐标的相对偏移。
  ///
  /// 返回的是**占最大可平移量的比例**（每个轴 0..1，取绝对值），而不是像素：
  /// 被控端要的是「画面挪了多少比例的原始宽高」，只有控制端知道视口大小，
  /// 所以必须由这里统一除，避免手势层和各调用点各算一套。
  /// `scale <= 1` 时没有可平移空间，一律 0。
  Offset normalizedOffset(Size viewport) {
    if (scale <= 1.0 || viewport.width <= 0 || viewport.height <= 0) {
      return Offset.zero;
    }
    final double maxX = viewport.width * (scale - 1.0);
    final double maxY = viewport.height * (scale - 1.0);
    return Offset((offset.dx / maxX).abs(), (offset.dy / maxY).abs());
  }

  ViewTransform copyWith({double? scale, Offset? offset}) =>
      ViewTransform(scale: scale ?? this.scale, offset: offset ?? this.offset);

  /// 按 [scale] 夹取 offset：`scale <= 1` 时画面比视口小，没有可平移的余量，
  /// offset 必须归零；`scale > 1` 时每轴只能落在 `[-viewport * (scale - 1), 0]`。
  ///
  /// 写成静态是为了让 [zoomAt] 能用**新** scale 夹取，而不必先构造半成品对象。
  static Offset _clampFor(double scale, Offset value, Size viewport) {
    if (scale <= 1.0) return Offset.zero;
    final double maxX = viewport.width * (scale - 1.0);
    final double maxY = viewport.height * (scale - 1.0);
    return Offset(
      value.dx.clamp(-maxX, 0.0).toDouble(),
      value.dy.clamp(-maxY, 0.0).toDouble(),
    );
  }

  @override
  String toString() => 'ViewTransform(scale: $scale, offset: $offset)';
}

/// 一笔：归一化坐标（0..1）的点序列 + 颜色 + 线宽。
///
/// 点存归一化值而不是像素值：窗口一 resize/缩放，像素坐标全废，
/// 归一化点乘当前视口即可，批注在缩放后依然贴在原来的画面内容上。
class AnnotationStroke {
  AnnotationStroke({
    required this.points,
    this.colorArgb = 0xFFFF3B30,
    this.width = 3.0,
  });

  final List<Offset> points;

  /// ARGB 颜色（默认红色，与官方批注一致，深色/浅色画面上都显眼）。
  final int colorArgb;

  /// 线宽（逻辑像素）。
  final double width;

  bool get isEmpty => points.isEmpty;
}

/// 批注笔画集合（含「正在画的那一笔」）。
///
/// 为什么要有上限：批注是**临时叠加层**，官方也不持久化。用户长时间挂着
/// 边讲边画，一天下来几万笔、每笔上千点，内存和重绘开销都会失控；
/// 到上限就让 UI 提示清空，比默默卡死好。
class AnnotationBoard {
  /// 最多保留的笔画数。
  static const int maxStrokes = 200;

  /// 单笔最多点数（防抖过滤后仍可能很长，比如大屏快速划一圈）。
  static const int maxPointsPerStroke = 2000;

  /// 相邻两点最小归一化距离。鼠标/触控笔的抖动会产生大量亚像素点，
  /// 0.002 约等于 1080P 下 3.8px，肉眼无感但能砍掉一半以上的点。
  static const double _minPointDistance = 0.002;

  final List<AnnotationStroke> _strokes = <AnnotationStroke>[];

  /// 正在进行中的笔画（已加入 [_strokes]，收笔时才决定去留）。
  AnnotationStroke? _active;

  /// 变更计数，供 CustomPainter 的 `shouldRepaint` 用。
  int _revision = 0;

  /// 已完成的笔画 + 正在进行的一笔（只读视图）。
  List<AnnotationStroke> get strokes => List<AnnotationStroke>.unmodifiable(_strokes);

  bool get isEmpty => _strokes.isEmpty;

  /// 每次变更 +1。painter 只比较这个整数，比深比较点列表便宜得多。
  int get revision => _revision;

  /// 起笔。返回 false 表示已到 [maxStrokes] 上限（应提示用户清空）。
  ///
  /// 新笔画立刻进 [_strokes]：这样「画到一半」的线也能被 painter 看到，
  /// 不用额外维护一份预览数据。
  bool begin(Offset point, {int colorArgb = 0xFFFF3B30, double width = 3.0}) {
    // 上笔没收到 end 就又起笔（多点触控、指针事件丢失）：先收掉，否则两笔会粘连，
    // 后面的 extend 全画到旧笔上。
    if (_active != null) end();
    if (_strokes.length >= maxStrokes) return false;
    final AnnotationStroke stroke = AnnotationStroke(
      points: <Offset>[point],
      colorArgb: colorArgb,
      width: width,
    );
    _strokes.add(stroke);
    _active = stroke;
    _revision++;
    return true;
  }

  /// 续笔。没有进行中的笔画、点太近（抖动）、或已到点数上限时返回 false。
  ///
  /// 返回 false 只代表「这个点没进去」，不是致命错误，手势层可以无脑忽略。
  bool extend(Offset point) {
    final AnnotationStroke? stroke = _active;
    if (stroke == null) return false;
    if (stroke.points.length >= maxPointsPerStroke) return false;
    if ((point - stroke.points.last).distance < _minPointDistance) return false;
    stroke.points.add(point);
    _revision++;
    return true;
  }

  /// 收笔：点太少（< 2）的笔画丢弃——误触/单击不该留下一个点。
  ///
  /// 无论丢弃与否都 +1：painter 需要收到一次通知来抹掉「正在画」的临时笔迹。
  void end() {
    final AnnotationStroke? stroke = _active;
    _active = null;
    if (stroke != null && stroke.points.length < 2) {
      _strokes.remove(stroke);
    }
    _revision++;
  }

  /// 撤销最后一笔。空列表调用安全（不发通知，因为没有任何变化）。
  void undo() {
    // 撤销也作用于正在画的那笔：它就在列表末尾，一并撤掉更符合直觉。
    _active = null;
    if (_strokes.isEmpty) return;
    _strokes.removeLast();
    _revision++;
  }

  /// 清空全部。空列表调用安全。
  void clear() {
    _active = null;
    if (_strokes.isEmpty) return;
    _strokes.clear();
    _revision++;
  }

  /// 把最后完成的一笔按 [viewport] 缩放进像素坐标，供 painter 直接画。
  ///
  /// 空画板或视口尺寸为 0 时返回空列表（不抛异常：首帧之前 viewport 就是
  /// `Size.zero`，此时 painter 仍会被调用一次）。
  List<Offset> toPixels(Size viewport) {
    if (_strokes.isEmpty) return const <Offset>[];
    if (viewport.width <= 0 || viewport.height <= 0) return const <Offset>[];
    return _scalePoints(_strokes.last.points, viewport);
  }

  /// 最近一笔的**归一化**点。
  ///
  /// painter 缓存 viewport 时用自己的尺寸换算即可，避免每帧都让 board 重新
  /// 分配一次像素点数组（60fps 下一秒钟 60 次垃圾回收很浪费）。
  List<Offset> get activeNormalizedPoints =>
      _strokes.isEmpty ? const <Offset>[] : _strokes.last.points;

  List<Offset> _scalePoints(List<Offset> points, Size viewport) {
    final List<Offset> result = <Offset>[];
    for (final Offset p in points) {
      result.add(Offset(p.dx * viewport.width, p.dy * viewport.height));
    }
    return result;
  }
}

/// 观看模式工具栏的可见性与当前状态。
///
/// 三态 + 工具栏可见性 + 变换打包成一个不可变值：页面只需要
/// `setState(() => _viewMode = _viewMode.copyWith(...))`，
/// 不用担心「改了工具栏可见性却忘了重建变换」这类半更新状态。
class ViewModeState {
  const ViewModeState({
    this.state = ViewState.control,
    this.toolbarVisible = true,
    this.transform = const ViewTransform(),
  });

  final ViewState state;

  /// 工具栏是否显示。官方 `viewModeToggleToolbar`，隐藏后靠快捷键唤回。
  final bool toolbarVisible;

  final ViewTransform transform;

  /// 观看态（含批注态）才能开批注：操控态下画笔会抢走直接操作的手势。
  bool get canAnnotate => state != ViewState.control;

  ViewModeState copyWith({
    ViewState? state,
    bool? toolbarVisible,
    ViewTransform? transform,
  }) =>
      ViewModeState(
        state: state ?? this.state,
        toolbarVisible: toolbarVisible ?? this.toolbarVisible,
        transform: transform ?? this.transform,
      );

  @override
  String toString() =>
      'ViewModeState(state: ${state.label}, toolbarVisible: $toolbarVisible, '
      'transform: $transform)';
}
