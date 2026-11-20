import 'package:material_ui/material_ui.dart';

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