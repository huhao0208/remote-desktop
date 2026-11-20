/// 全局常量：服务端默认地址、画质档位（与 `srv2/control.html` 完全一致）。
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

  /// 画质档位：value = `width,quality,bitrate`，见 docs/media-protocol.md §4。
  static const List<QualityPreset> qualityPresets = <QualityPreset>[
    QualityPreset('流畅', 1280, 55, 4000),
    QualityPreset('高清（默认）', 1920, 75, 8000),
    QualityPreset('超清', 2560, 80, 20000),
  ];

  /// 默认档位索引（高清）。
  static const int defaultQualityIndex = 1;

  /// JPEG 兜底通路的看门狗阈值：超过这个时间没有新帧就提示断流。
  static const Duration frameWatchdog = Duration(seconds: 4);

  /// 输入事件最小发送间隔（move 高频事件限流）。
  static const Duration inputThrottle = Duration(milliseconds: 16);
}

class QualityPreset {
  const QualityPreset(this.label, this.width, this.quality, this.bitrate);

  final String label;
  final int width;
  final int quality;
  final int bitrate; // kbps，仅 WebRTC 生效

  String get value => '$width,$quality,$bitrate';

  static QualityPreset fromValue(String? value) {
    if (value != null) {
      for (final p in AppConfig.qualityPresets) {
        if (p.value == value) return p;
      }
      final parts = value.split(',').map(int.tryParse).toList();
      if (parts.length == 3 && parts[0] != null && parts[1] != null && parts[2] != null) {
        return QualityPreset('自定义', parts[0]!, parts[1]!, parts[2]!);
      }
    }
    return AppConfig.qualityPresets[AppConfig.defaultQualityIndex];
  }
}