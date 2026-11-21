/// 全局常量：服务端默认地址、画质档位（对齐官方 `Control.Menu.Quality.*` 6 档）。
class AppConfig {
  AppConfig._();

  /// 编译期覆盖：`flutter run --dart-define=UU_SERVER=https://host:8444`。
  ///
  /// 本地联调时不用去改 shared_preferences（沙盒/新装环境下很难验），直接钉死服务端。
  static const String _envServer = String.fromEnvironment('UU_SERVER');

  /// 自托管服务端默认地址。内置常量，可在登录页/设备列表的「设置」里修改。
  ///
  /// 优先级：`--dart-define=UU_SERVER` > 内置常量 > 用户保存的地址（见 `Settings.serverBase`）。
  static const String defaultServer =
      _envServer == '' ? 'https://47-251-105-202.sslip.io:8444' : _envServer;

  /// 自动升级查询的 GitHub 仓库（`owner/repo`）。
  ///
  /// 直连 `GET /repos/<repo>/releases/latest`，匿名可用（60 次/小时/IP，
  /// 命中 ETag 的 304 不计数，客户端 24h 才真正请求一次）。
  /// fork 或自建镜像可用 `--dart-define=UU_RELEASE_REPO=owner/repo` 覆盖。
  static const String _envReleaseRepo = String.fromEnvironment('UU_RELEASE_REPO');
  static const String releaseRepo =
      _envReleaseRepo == '' ? 'huhao0208/remote-desktop' : _envReleaseRepo;

  /// 画质 6 档（官方：自动 / 省流 480P / 高清 1080P / 超清 2K / 蓝光 4K / 原画）。
  ///
  /// `width == 0` 表示**不缩放**（跟随被控端源分辨率）；`bitrate == 0` 表示
  /// 码率自动（由档位宽度 + 帧率推算，见 [StreamPrefs.autoBitrate]）。
  static const List<QualityPreset> qualityPresets = <QualityPreset>[
    QualityPreset('auto', '自动', '动态', 0, 72, 0),
    QualityPreset('speed', '省流', '480P', 854, 55, 3000),
    QualityPreset('normal', '高清', '1080P', 1920, 75, 8000),
    QualityPreset('hd', '超清', '2K', 2560, 80, 20000),
    QualityPreset('blue', '蓝光', '4K', 3840, 85, 40000),
    QualityPreset('original', '原画', '源分辨率', 0, 90, 60000),
  ];

  /// 默认档位索引（高清 1080P，与官方默认一致）。
  static const int defaultQualityIndex = 2;

  /// 帧率上限可选值（官方 `FrameLimit` 四档，默认 60）。
  static const List<int> fpsOptions = <int>[30, 60, 90, 144];

  /// 默认帧率。
  static const int defaultFps = 60;

  /// 分辨率选项：`width == 0` = 不缩放。
  ///
  /// `follow_local` 的实际宽度在打开面板时按控制端窗口像素宽度算出来，
  /// 这里只是占位（0 会被 UI 换成实时值）。
  static const List<ResolutionOption> resolutions = <ResolutionOption>[
    ResolutionOption('follow_local', '跟随当前显示屏', 0),
    ResolutionOption('follow_remote', '跟随被控端', 0),
    ResolutionOption('480p', '480P', 854),
    ResolutionOption('1080p', '1080P', 1920),
    ResolutionOption('2k', '2K', 2560),
    ResolutionOption('4k', '4K', 3840),
  ];

  /// 自定义码率滑块范围（kbps）。上限取官方标称 500Mbps 里对自建有意义的一段：
  /// 家用上行 100Mbps 已经很顶，50Mbps 足够 4K60，再高只会在弱网里更糟。
  static const int minCustomBitrate = 1000;
  static const int maxCustomBitrate = 50000;

  /// JPEG 兜底通路的看门狗阈值：超过这个时间没有新帧就提示断流。
  static const Duration frameWatchdog = Duration(seconds: 4);

  /// 输入事件最小发送间隔（move 高频事件限流）。
  static const Duration inputThrottle = Duration(milliseconds: 16);
}

/// 一档画质。字段含义见 [AppConfig.qualityPresets]。
class QualityPreset {
  const QualityPreset(this.key, this.label, this.hint, this.width, this.quality, this.bitrate);

  final String key;
  final String label;

  /// 副标题（`480P` / `1080P` / `源分辨率`），空串表示不显示。
  final String hint;

  /// 目标最大宽度；`0` = 不缩放。
  final int width;

  /// JPEG 质量（仅 JPEG 兜底通路）。
  final int quality;

  /// 目标码率 kbps；`0` = 自动。
  final int bitrate;

  /// 持久化值：用 key（老版本存的是 `width,quality,bitrate`，[fromValue] 兼容）。
  String get value => key;

  String get display => hint.isEmpty ? label : '$label（$hint）';

  String get resolutionLabel => width <= 0 ? '源分辨率' : '${width}P';

  static QualityPreset fromValue(String? value) {
    if (value != null && value.isNotEmpty) {
      // 新格式：key
      for (final QualityPreset p in AppConfig.qualityPresets) {
        if (p.key == value) return p;
      }
      // 老格式：`width,quality,bitrate` —— 按参数回查，让升级用户停在原档位
      final List<int?> parts = value.split(',').map(int.tryParse).toList();
      if (parts.length == 3 && !parts.contains(null)) {
        for (final QualityPreset p in AppConfig.qualityPresets) {
          if (p.width == parts[0] && p.quality == parts[1] && p.bitrate == parts[2]) {
            return p;
          }
        }
        // 老的自定义档：参数对不上任何预设，按宽度就近归到 1080P/2K
        final int w = parts[0]!;
        if (w <= 1024) return AppConfig.qualityPresets[1];
        if (w <= 1920) return AppConfig.qualityPresets[2];
        if (w <= 2560) return AppConfig.qualityPresets[3];
        return AppConfig.qualityPresets[4];
      }
    }
    return AppConfig.qualityPresets[AppConfig.defaultQualityIndex];
  }
}

/// 分辨率选项。[key] 用于持久化，[width] 为 0 时按 [key] 解释语义。
class ResolutionOption {
  const ResolutionOption(this.key, this.label, this.width);

  final String key;
  final String label;
  final int width;

  static ResolutionOption fromKey(String? key) {
    for (final ResolutionOption r in AppConfig.resolutions) {
      if (r.key == key) return r;
    }
    return AppConfig.resolutions[0];
  }
}

/// 一次会话的画质参数（档位 + 分辨率覆盖 + 帧率 + 码率覆盖）。
///
/// 为什么要单独一层：官方「画质档」和「分辨率/帧率/码率」是**互相覆盖**的关系——
/// 换档位会重置分辨率，手动选分辨率又只改分辨率。把最终值收敛到这里，
/// `stream.config` 只从这里取值，避免页面里散着一堆三元表达式。
class StreamPrefs {
  const StreamPrefs({
    required this.preset,
    this.resolutionKey = 'preset',
    this.resolutionWidth = 0,
    this.fps = AppConfig.defaultFps,
    this.bitrateOverride = 0,
    this.customBitrate = false,
  });

  final QualityPreset preset;

  /// 分辨率选择：`preset`（跟随档位）/ `follow_local` / `follow_remote` /
  /// `480p` / `1080p` / `2k` / `4k`。
  final String resolutionKey;

  /// `follow_local` 时按控制端窗口算出的像素宽（其余情况仅作缓存）。
  final int resolutionWidth;
  final int fps;
  final int bitrateOverride;
  final bool customBitrate;

  /// 实际发给 Agent 的宽度：`0` = 不缩放。
  int get width {
    switch (resolutionKey) {
      case 'preset':
        return preset.width;
      case 'follow_remote':
        return 0;
      case 'follow_local':
        return resolutionWidth > 0 ? resolutionWidth : preset.width;
      default:
        final int fixed = ResolutionOption.fromKey(resolutionKey).width;
        if (fixed > 0) return fixed;
        return resolutionWidth > 0 ? resolutionWidth : preset.width;
    }
  }

  /// 实际码率：自定义优先，其次档位，最后按宽度/帧率推算。
  int get bitrate {
    if (customBitrate && bitrateOverride > 0) return bitrateOverride;
    if (preset.bitrate > 0) return preset.bitrate;
    return autoBitrate(width, fps);
  }

  /// 自动码率：按「每像素每帧 0.06 bit」估算（1080p60 ≈ 7.5 Mbps，
  /// 与官方「高清 1080P」一档的手感接近）；宽度缺失时按 1080P 保守给。
  static int autoBitrate(int width, int fps) {
    final int w = width > 0 ? width : 1920;
    final int h = (w * 9 / 16).round();
    final double raw = w * h * fps * 0.06 / 1000; // kbps
    return raw.clamp(1500, 50000).round();
  }

  /// 顶栏按钮文案：`高清 · 60fps`。
  String get label => '${preset.label} · ${fps}fps';

  String get resolutionLabel {
    if (resolutionKey == 'preset') {
      return preset.width <= 0 ? '跟随被控端' : '${preset.width}P';
    }
    if (resolutionKey == 'follow_remote') return '跟随被控端';
    if (resolutionKey == 'follow_local') {
      return resolutionWidth > 0 ? '跟随当前显示屏（${resolutionWidth}P）' : '跟随当前显示屏';
    }
    return ResolutionOption.fromKey(resolutionKey).label;
  }

  StreamPrefs copyWith({
    QualityPreset? preset,
    String? resolutionKey,
    int? resolutionWidth,
    int? fps,
    int? bitrateOverride,
    bool? customBitrate,
  }) =>
      StreamPrefs(
        preset: preset ?? this.preset,
        resolutionKey: resolutionKey ?? this.resolutionKey,
        resolutionWidth: resolutionWidth ?? this.resolutionWidth,
        fps: fps ?? this.fps,
        bitrateOverride: bitrateOverride ?? this.bitrateOverride,
        customBitrate: customBitrate ?? this.customBitrate,
      );
}
