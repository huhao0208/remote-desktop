import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'core/agent_host.dart';
import 'core/settings.dart';
import 'core/theme.dart';
import 'core/window_setup.dart';
import 'pages/device_list_page.dart';
import 'pages/login_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Settings.init();
  await setupDesktopWindow();
  runApp(const UuRemoteApp());
  // 冷启动带会话 → 顺手把内置被控端拉起来（桌面端才有；移动端是 unsupported）
  if (Settings.hasSession) unawaited(AgentHost.instance.syncSession());
}

class UuRemoteApp extends StatelessWidget {
  const UuRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UU Remote',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const _Bootstrap(),
    );
  }
}

/// 有本地会话直接进设备列表，否则回登录页。
class _Bootstrap extends StatelessWidget {
  const _Bootstrap();

  @override
  Widget build(BuildContext context) {
    return Settings.hasSession ? const DeviceListPage() : const LoginPage();
  }
}