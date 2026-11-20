import 'dart:io';

import 'settings.dart';

/// 本机身份：登录注册设备时用的稳定指纹 + 展示名 + 平台标识。
class DeviceIdentity {
  DeviceIdentity._();

  static String get uuid => Settings.deviceUuid;

  /// 平台标识：桌面端登记为 `pc`（服务端只把 pc/mac/linux 视为「可控」），
  /// 移动端登记为 `mobile`，避免手机把自己伪装成一台可被远控的电脑。
  static String get platform {
    if (Platform.isAndroid || Platform.isIOS) return 'mobile';
    return 'pc';
  }

  static String get name {
    try {
      final host = Platform.localHostname.trim();
      if (host.isNotEmpty) return host;
    } catch (_) {
      // 某些平台取主机名会抛异常，走兜底名
    }
    if (Platform.isAndroid) return 'Android 控制端';
    if (Platform.isIOS) return 'iOS 控制端';
    if (Platform.isMacOS) return 'Mac 控制端';
    if (Platform.isWindows) return 'Windows 控制端';
    if (Platform.isLinux) return 'Linux 控制端';
    return 'Flutter 控制端';
  }
}