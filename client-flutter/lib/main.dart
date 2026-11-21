import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'core/agent_host.dart';
import 'core/lock_service.dart';
import 'core/settings.dart';
import 'core/theme.dart';
import 'core/window_setup.dart';
import 'pages/device_list_page.dart';
import 'pages/login_page.dart';
import 'widgets/lock_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Settings.init();
  await setupDesktopWindow();
  // 客户端锁必须在 runApp 之前完成：否则首帧会先渲染设备列表再被锁屏盖住，
  // 用户能瞥见主界面内容（不只是难看，是隐私问题）。
  await LockService.instance.init();
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

/// 有本地会话直接进设备列表，否则回登录页；锁屏时在整棵树上盖一层。
///
/// 用 Stack 叠加而不是替换根页面：解锁后底下那页还在原来的状态，
/// 不会因为「解锁」而重新拉一次设备列表、重连一次信令。
class _Bootstrap extends StatelessWidget {
  const _Bootstrap();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: LockService.instance.locked,
      builder: (BuildContext context, bool locked, Widget? _) {
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Settings.hasSession ? const DeviceListPage() : const LoginPage(),
            if (locked) const LockScreen(),
          ],
        );
      },
    );
  }
}