// 预览截图脚本：默认跳过（真实网络 + 假服务端，只为本机看效果）。
// 运行：flutter test --tags preview test/_preview_test.dart
@Tags(<String>['preview'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uu_remote/core/settings.dart';
import 'package:uu_remote/core/theme.dart';
import 'package:uu_remote/pages/device_list_page.dart';
import 'package:uu_remote/pages/login_page.dart';

/// 临时 UI 预览脚本（不入库）：把页面渲染成 PNG，人工核对视觉。
/// 用法：flutter test test/_preview_test.dart --plain-name preview
const String outDir = '/tmp/ui_preview';

Map<String, dynamic> _device(
  String id,
  String name,
  String platform, {
  bool online = true,
  bool isSelf = false,
  bool controllable = true,
  int agoMs = 20000,
}) =>
    <String, dynamic>{
      'device_id': id,
      'device_name': name,
      'platform': platform,
      'online': online,
      'is_self': isSelf,
      'controllable': controllable,
      'last_seen': DateTime.now().millisecondsSinceEpoch - agoMs,
    };

Future<HttpServer> _startFakeServer() async {
  final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((HttpRequest req) async {
    final String body = await utf8.decoder.bind(req).join();
    stdout.writeln('[fake] ${req.method} ${req.uri.path} body=$body');
    Map<String, dynamic> data;
    if (req.uri.path.contains('login')) {
      data = <String, dynamic>{
        'token': 'tok-preview',
        'uid': '1',
        'mobile': '13800138000',
        'nickname': 'hoha',
        'device_id': 'self-001',
      };
    } else if (req.uri.path.contains('device/list')) {
      data = <String, dynamic>{
        'list': <Map<String, dynamic>>[
          _device('pc-001', 'PC-Workstation', 'pc'),
          _device('tv-001', '客厅电视', 'android_tv'),
          _device('mac-001', 'MacBook-Pro', 'pc', online: false, agoMs: 3 * 3600 * 1000),
          _device('self-001', '我的手机', 'mobile', isSelf: true, controllable: false),
        ],
      };
    } else {
      data = <String, dynamic>{};
    }
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(<String, dynamic>{'code': 0, 'msg': 'ok', 'data': data}));
    await req.response.close();
    body.length;
  });
  return server;
}

Future<void> _loadFont() async {
  Future<void> load(String family, String path) async {
    // 字体文件只在本机准备，缺失时跳过（不让预览脚本在别的机器上崩）
    final File file = File(path);
    if (!file.existsSync()) return;
    final ByteData data = file.readAsBytesSync().buffer.asByteData();
    await (FontLoader(family)..addFont(Future<ByteData>.value(data))).load();
  }

  // 测试环境默认字体是 Ahem（全方块），这里注入真实字体：中文 + Material 图标
  const String cjk = '/tmp/uifonts/NotoSansSC.ttf';
  const String icons = '/vol5/@appdata/trim.hermes/workspace/tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
  for (final String family in <String>['Roboto', 'Roboto Medium', 'NotoSansSC', '.SF UI Text', '.AppleSystemUIFont', 'Segoe UI', 'Ubuntu', 'Noto Sans', 'DejaVu Sans', 'sans-serif']) {
    await load(family, cjk);
  }
  await load('MaterialIcons', icons);
}


/// 真实网络在 widget test 里必须反复「让出时间片」才能推进：多轮 runAsync + pump。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _shot(WidgetTester tester, GlobalKey key, String name) async {
  await tester.runAsync(() async {
    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage(pixelRatio: 2);
    final ByteData? bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(outDir).createSync(recursive: true);
    File('$outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  late HttpServer server;
  late String base;

  setUpAll(() async {
    Directory(outDir).createSync(recursive: true);
    // flutter_test 默认用返回 400 的假 HttpClient 拦截真实网络，这里恢复真网络（仅预览用）
    HttpOverrides.global = null;
    server = await _startFakeServer();
    base = 'http://127.0.0.1:${server.port}';
    await _loadFont();
  });

  tearDownAll(() async => server.close(force: true));

  Widget host(Widget child, {required Size size}) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(fontFamily: 'NotoSansSC'),
      home: child,
    );
  }

  testWidgets('preview login + device list', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues(<String, Object>{
      'server_base': 'https://uu.example.com:8444',
      'auth_mobile': '13800138000',
      'device_uuid': 'self-001',
      'quality_preset': '1920,80,4000',
    });
    await Settings.init();

    final GlobalKey loginKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: loginKey, child: host(const LoginPage(), size: const Size(1440, 900))));
    await tester.pump(const Duration(milliseconds: 400));
    await _shot(tester, loginKey, '01-login-desktop');

    // 宽屏设备列表
    SharedPreferences.setMockInitialValues(<String, Object>{
      'server_base': base,
      'auth_token': 'tok-preview',
      'auth_uid': '1',
      'auth_mobile': '13800138000',
      'auth_nickname': 'hoha',
      'device_uuid': 'self-001',
      'device_id': 'self-001',
      'quality_preset': '1920,80,4000',
    });
    await Settings.init();

    final GlobalKey listKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: listKey, child: host(const DeviceListPage(), size: const Size(1440, 900))),
    );
    await _settle(tester);
    
    await _shot(tester, listKey, '02-devices-desktop');

    // 窄屏设备列表（手机）
    tester.view.physicalSize = const Size(390, 844);
    final GlobalKey phoneKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: phoneKey, child: host(const DeviceListPage(), size: const Size(390, 844))),
    );
    await _settle(tester);
    await _shot(tester, phoneKey, '03-devices-phone');
    // 卸载页面，取消内部轮询 Timer，否则测试结束会报 pending timer
    await tester.pumpWidget(const SizedBox());

    // 窄屏登录页
    final GlobalKey loginPhone = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: loginPhone, child: host(const LoginPage(), size: const Size(390, 844))),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await _shot(tester, loginPhone, '04-login-phone');
  });
}