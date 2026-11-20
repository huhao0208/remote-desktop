import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'agent_host.dart';

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
    // 关窗口前先收掉被控端：不然 uu-agent 会变成孤儿进程继续对外提供服务
    await windowManager.setPreventClose(true);
    windowManager.addListener(_AgentShutdownListener());
  } catch (_) {
    // 窗口插件在个别环境不可用（例如无窗口系统），静默降级，不影响主流程
  }
}

class _AgentShutdownListener with WindowListener {
  @override
  void onWindowClose() {
    unawaited(_shutdown());
  }

  Future<void> _shutdown() async {
    try {
      await AgentHost.instance.stop();
    } catch (_) {
      // 杀进程失败也不能把窗口卡住
    } finally {
      try {
        await windowManager.destroy();
      } catch (_) {
        // 已经销毁
      }
    }
  }
}