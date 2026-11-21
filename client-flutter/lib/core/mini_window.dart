import 'dart:ui' show Offset, Size;

/// 远控「小窗模式」（官方 B5：置顶 / 不透明度 / 小窗内切屏 / 单设备 / 退出）的状态与几何计算。
///
/// 为什么单独抽一层：
/// - 小窗的**手感**几乎全在几何上——初始摆右下角、松手吸边、拖出行程要能拖回来。
///   这些算式散在页面里会被 `setState` 和 `window_manager` 的异步调用搅在一起，
///   一旦「窗口拖丢找不回来」这种问题出现，只能上真机手拖复现。
///   收敛成纯函数后，边界值可以在单测里一眼钉死（毫秒级跑完，不用起窗口）。
/// - 平台差异（`window_manager` 在 Linux 上不支持逐帧透明、macOS 的置顶层级不同）属于
///   落地层的锅，**不在这里判断**。本文件只依赖 `dart:ui` 的 [Size] / [Offset]，
///   既能在 UI 线程算，也能在纯 Dart 环境（单测）算。
///
/// 设计取舍：
/// - 所有方法**不抛异常**：窗口尺寸在首帧前可能还是 `Size.zero`，屏幕信息在
///   多屏切换瞬间可能读不到。宁可返回一个「能用但保守」的值，也不要让用户看到红屏。
/// - 尺寸按被控端**宽高比**算，而不是写死 16:9：被控端可能是竖屏手机、带鱼屏、
///   4:3 老机器，画面被拉扁比小一点更难受。
class MiniWindowState {
  const MiniWindowState({
    this.enabled = false,
    this.alwaysOnTop = true,
    this.opacity = 0.95,
    this.size = MiniWindowSize.normal,
    this.movable = true,
  });

  /// 是否处于小窗模式。为 false 时其余字段仍有意义——它们是小窗的「记忆」，
  /// 下次进小窗沿用上次的档位/透明度，不用每次重调。
  final bool enabled;

  /// 置顶：小窗的意义就是「一边干别的活一边瞟画面」，不置顶等于普通窗口，官方默认开。
  final bool alwaysOnTop;

  /// 不透明度，`0.3 ~ 1.0`。默认 0.95 而不是 1.0：留一点点透明，用户能看出「这是浮窗」，
  /// 又不会因为太透而看不清画面内容（低于 0.3 连文字都糊了，见 [MiniWindowLayout.minOpacity]）。
  final double opacity;

  /// 尺寸档位，见 [MiniWindowSize]。
  final MiniWindowSize size;

  /// 是否允许拖动。锁定后窗口钉在原地，防误拖（小窗常被当成浮窗推来推去）。
  final bool movable;

  /// 派生新状态；未传的字段沿用旧值。
  ///
  /// [opacity] 在这里统一夹取：滑块/快捷键/配置回填都可能塞进 0.1 或 2.0，
  /// 越界值交给 `window_manager` 会得到「完全透明看不见」或者平台直接忽略，
  /// 两者都表现为「点了没反应」，很难查。[double.nan] 同样落到 [MiniWindowLayout.minOpacity]：
  /// 宁可让窗口偏透明，也不要传 NaN 让整条渲染链失效。
  MiniWindowState copyWith({
    bool? enabled,
    bool? alwaysOnTop,
    double? opacity,
    MiniWindowSize? size,
    bool? movable,
  }) =>
      MiniWindowState(
        enabled: enabled ?? this.enabled,
        alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
        opacity: MiniWindowLayout.clampOpacity(opacity ?? this.opacity),
        size: size ?? this.size,
        movable: movable ?? this.movable,
      );

  /// 只持久化「偏好」，**不含 [enabled]**。
  ///
  /// 小窗是运行态：用户上次退出时如果进程被杀，`enabled: true` 存下来会让
  /// 下次进远控页直接变成一个小窗口，看起来像「界面坏了」。进页面永远从
  /// 正常窗口开始，用户想用小窗再点。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'alwaysOnTop': alwaysOnTop,
        'opacity': opacity,
        'size': size.name,
        'movable': movable,
      };

  /// 容错解析：字段缺失或类型不对一律回落默认值。
  /// 配置只影响体验，不该让「JSON 里有个字符串」变成进不了远控页。
  factory MiniWindowState.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const MiniWindowState();
    MiniWindowSize size = MiniWindowSize.normal;
    final Object? rawSize = json['size'];
    for (final MiniWindowSize candidate in MiniWindowSize.values) {
      if (candidate.name == rawSize) size = candidate;
    }
    final Object? rawOpacity = json['opacity'];
    final Object? top = json['alwaysOnTop'];
    final Object? movable = json['movable'];
    return MiniWindowState(
      alwaysOnTop: top is bool ? top : true,
      opacity: rawOpacity is num
          ? MiniWindowLayout.clampOpacity(rawOpacity.toDouble())
          : 0.95,
      size: size,
      movable: movable is bool ? movable : true,
    );
  }
}

/// 小窗尺寸档位。官方只给「小窗效果预览」没给固定尺寸，这里给三档。
///
/// 用档位而不是自由拖拽改尺寸：小窗的使用场景是「瞟一眼」，
/// 三档够用且记住一个枚举比重存像素宽高稳（换屏、缩放比变化时不会出现 100px 宽的怪窗口）。
enum MiniWindowSize {
  compact,
  normal,
  large;

  /// 面板上的中文名（官方 UI 的按钮文案）。
  String get label {
    switch (this) {
      case MiniWindowSize.compact:
        return '紧凑';
      case MiniWindowSize.normal:
        return '标准';
      case MiniWindowSize.large:
        return '大';
    }
  }

  /// 相对 `screen.shortestSide` 的短边系数。
  ///
  /// 为什么按短边：横屏 1920×1080 上 normal = 短边的一半（540），
  /// 窗口正好是屏幕 1/2 × 1/2、面积 1/4——「一眼看全又不挡事」，
  /// 换成按宽度算，竖屏或带鱼屏上会得到完全不成比例的结果。
  double get factor {
    switch (this) {
      case MiniWindowSize.compact:
        return 0.34;
      case MiniWindowSize.normal:
        return 0.5;
      case MiniWindowSize.large:
        return 0.68;
    }
  }
}

/// 小窗的几何计算（纯静态函数，无状态、无副作用）。
class MiniWindowLayout {
  MiniWindowLayout._();

  /// 透明度夹取区间：低于 [minOpacity] 根本看不清画面，高于 1 无意义。
  static const double minOpacity = 0.3;
  static const double maxOpacity = 1.0;

  /// 窗口最多占可用区的比例。
  ///
  /// 0.75 是「再大就不像小窗」的临界：超过 3/4 后原本的窗口被压得只剩一条边，
  /// 用户想切回全屏的点击区域都找不到了。这个上限在极端比例（竖屏被控端）下才真正起作用。
  static const double maxRatio = 0.75;

  /// 最小可读尺寸。低于这个值画面里的字全是马赛克，不如不给小窗。
  static const double minWidth = 160;
  static const double minHeight = 90;

  /// 最小尺寸常量（供退化输入兜底和 UI 校验复用）。
  static const Size minSize = Size(minWidth, minHeight);

  /// 窗口尺寸：按被控端画面比例算，且不超过可用区的 [maxRatio]（默认 0.75）。
  ///
  /// 算法分三步，顺序不能换：
  /// 1. 以 `screen.shortestSide × 档位系数` 作为**短边**，按被控端宽高比推出长边；
  /// 2. 按可用区的 75% 等比收缩（取宽/高两个约束里更严的那个，保证比例不变）；
  /// 3. 向下取整到整数像素——半像素会让视频层出现一条 1px 的缝，比多 1px 黑边更丑。
  ///
  /// [desktopResolution] 宽或高为 0（还没收到 hello）时退回 [screen] 的比例：
  /// 此时按屏幕猜一个，等 hello 到了会再算一次，首次显示不至于给个正方形。
  static Size windowSize({
    required Size screen,
    required Size desktopResolution,
    MiniWindowSize size = MiniWindowSize.normal,
  }) {
    final double screenW = _sane(screen.width);
    final double screenH = _sane(screen.height);
    // 屏幕都没读到（首帧前）时给最小尺寸，调用方拿到就能摆，不用判空。
    if (screenW <= 0 || screenH <= 0) return minSize;

    final double desktopW = _sane(desktopResolution.width);
    final double desktopH = _sane(desktopResolution.height);
    final double aspect = desktopW > 0 && desktopH > 0
        ? desktopW / desktopH
        : screenW / screenH;

    final double shortest = screenW < screenH ? screenW : screenH;
    final double base = shortest * size.factor;
    // aspect >= 1 表示横向画面：短边就是高；竖屏则反过来，短边是宽。
    double width = aspect >= 1 ? base * aspect : base;
    double height = aspect >= 1 ? base : base / aspect;

    // 极端宽高比（如被控端报 1×1000000）会算出 0/Infinity/NaN，
    // 直接拿去 `floorToDouble` 会抛异常，这里连同「算不出正尺寸」一起退回最小尺寸。
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return minSize;
    }

    final double capW = screenW * maxRatio;
    final double capH = screenH * maxRatio;
    double scale = 1;
    if (width > capW) scale = capW / width;
    if (height * scale > capH) scale = capH / height;
    width *= scale;
    height *= scale;

    // 极小屏（如 320×240 的分屏角落）上先把比例撑到最小可读尺寸，再取整；
    // 比例优先于「不超过 75%」，因为看不清的窗口没有存在意义。
    final double grow = _max(minWidth / width, minHeight / height);
    if (!grow.isFinite) return minSize;
    if (grow > 1) {
      width *= grow;
      height *= grow;
    }

    return Size(_floorAtLeast(width, minWidth), _floorAtLeast(height, minHeight));
  }

  /// 初始位置：右下角，距边 [margin]（默认 24）。
  ///
  /// 为什么固定右下角：主流远控/会议软件的小窗都停在这里，用户不需要找；
  /// 而且右下角通常压不到窗口的标题栏和侧边栏。算出来是负数（小屏幕 / 窗口比屏幕还大）
  /// 就夹到 0，让窗口贴左上角显示，至少标题栏还在屏内。
  static Offset initialPosition({
    required Size screen,
    required Size window,
    double margin = 24,
  }) {
    final double dx = _sane(screen.width) - _sane(window.width) - _sane(margin);
    final double dy = _sane(screen.height) - _sane(window.height) - _sane(margin);
    return Offset(_atLeastZero(dx), _atLeastZero(dy));
  }

  /// 拖动松手后的吸附：任一方向离边 < [threshold]（默认 16）就贴边。
  ///
  /// 为什么只吸边不吸网格：吸边对应「靠边挂机」这个真实用法（窗口贴右边缘不挡内容），
  /// 网格吸附在小窗这么小的尺寸上会让人误以为拖不动。
  ///
  /// 注意：这是**字面**判断「离边距离小于阈值」，坐标在屏幕外也满足条件，会被拉回屏内。
  /// 想保留「露出一点」的拖出效果，应先用 [clampToScreen] 再用本方法。
  static Offset snap({
    required Offset position,
    required Size screen,
    required Size window,
    double threshold = 16,
  }) {
    final double screenW = _sane(screen.width);
    final double screenH = _sane(screen.height);
    final double windowW = _sane(window.width);
    final double windowH = _sane(window.height);
    final double limit = _sane(threshold);

    double dx = _sane(position.dx);
    double dy = _sane(position.dy);

    if (dx < limit) {
      dx = 0;
    } else if (screenW - (dx + windowW) < limit) {
      dx = screenW - windowW;
    }
    if (dy < limit) {
      dy = 0;
    } else if (screenH - (dy + windowH) < limit) {
      dy = screenH - windowH;
    }
    return Offset(dx, dy);
  }

  /// 拖到屏幕外时的回收：保证至少 [visible] 像素（默认 48）留在屏内，
  /// 否则用户会把窗口拖丢找不回来。
  ///
  /// 为什么留 48：这个宽度足以露出窗口的一条边和半个标题栏按钮，
  /// 用户能一眼看见并拖回来；小于 24 就只有一条几乎看不见的像素缝了。
  ///
  /// 下界是负值——允许窗口左边/上边探出屏幕，这是「半挂在边上」的正常状态；
  /// 上界则保证右侧/底部至少留 [visible]。参数退化（窗口比 visible 还窄、
  /// 屏幕尺寸为 0）时返回一个不崩的安全值，不抛 [ArgumentError]。
  static Offset clampToScreen({
    required Offset position,
    required Size screen,
    required Size window,
    double visible = 48,
  }) {
    final double screenW = _sane(screen.width);
    final double screenH = _sane(screen.height);
    final double windowW = _sane(window.width);
    final double windowH = _sane(window.height);
    // visible 比窗口还大时以窗口为准：否则「至少留 visible」会把整个窗口推到屏外。
    final double keepX = _min(_atLeastZero(_sane(visible)), windowW);
    final double keepY = _min(_atLeastZero(_sane(visible)), windowH);

    return Offset(
      _clamp(_sane(position.dx), keepX - windowW, screenW - keepX),
      _clamp(_sane(position.dy), keepY - windowH, screenH - keepY),
    );
  }

  /// 把透明度夹到 `[minOpacity, maxOpacity]`；[double.nan] 落到 [minOpacity]。
  ///
  /// 公开出来是给主控接线用的：滑块 `onChanged` 与配置回填都会直接产出裸 double，
  /// 让它们走同一个函数，才不会出现「滑块显示 30%，窗口却是看不见」的分歧。
  static double clampOpacity(double value) {
    if (value.isNaN) return minOpacity;
    return _clamp(value, minOpacity, maxOpacity);
  }

  /// NaN / Infinity 一律视为不可用（返回 0），避免污染后面的乘除。
  static double _sane(double value) {
    if (value.isNaN || value.isInfinite) return 0;
    return value;
  }

  /// 向下取整并保证不小于 [atLeast]（浮点误差可能让 160 变成 159.99…）。
  static double _floorAtLeast(double value, double atLeast) {
    final double floored = value.floorToDouble();
    return floored < atLeast ? atLeast : floored;
  }

  static double _atLeastZero(double value) => value < 0 ? 0 : value;

  static double _min(double a, double b) => a < b ? a : b;

  static double _max(double a, double b) => a > b ? a : b;

  /// 自己实现夹取：`num.clamp` 在下界大于上界时会抛 [ArgumentError]，
  /// 而退化输入（窗口比屏幕还大）恰恰会产生这种区间。
  static double _clamp(double value, double lower, double upper) {
    if (lower > upper) return lower;
    if (value < lower) return lower;
    if (value > upper) return upper;
    return value;
  }
}
