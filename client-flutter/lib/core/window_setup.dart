import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

/// 桌面端窗口初始尺寸 / 最小尺寸。移动端直接跳过。
Future<void> setupDesktopWindow() async {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) return;
  try {
    await windowManager.ensureInitialized();
    const WindowOptions options = WindowOptions(
      size: Size(1280, 820),
      minimumSize: Size(1024, 680),
      center: true,
      title: 'UU Remote',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  } catch (_) {
    // 窗口插件在个别环境不可用（例如无窗口系统），静默降级，不影响主流程
  }
}