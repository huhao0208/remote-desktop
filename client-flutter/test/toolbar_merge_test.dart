// 单条工具栏合并（官方 B2 结构对齐）的回归测试。
//
// 用真实假服务端驱动 RemotePage（参考 _preview_remote_test.dart 的假服务器），
// 断言三条核心承诺：
//   1. 宽屏（1440）：顶栏出现 鼠标/外设/文件 三组入口（官方单条工具栏的对应组）
//   2. 窄屏（390）：顶栏**不**出现——硬塞会把设备名挤没（之前踩过的坑）
//   3. 窄屏时「更多」菜单里有这三项兜底，功能不能因为收窄就消失
//
// 跑法同默认套件：flutter test test/toolbar_merge_test.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uu_remote/core/models.dart';
import 'package:uu_remote/core/settings.dart';
import 'package:uu_remote/core/theme.dart';
import 'package:uu_remote/pages/remote_page.dart';

/// 客户端发到信令的消息（断言：合并不该改变消息行为）。
final List<Map<String, dynamic>> inbound = <Map<String, dynamic>>[];

Future<HttpServer> _startFake() async {
  final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final int port = server.port;
  server.listen((HttpRequest req) async {
    if (req.uri.path.endsWith('/ws/signaling')) {
      final WebSocket ws = await WebSocketTransformer.upgrade(req);
      ws.add(jsonEncode(<String, dynamic>{
        'p': 'agent.hello',
        'name': 'MacBook-Pro',
        'os': 'macos',
        'media': 'jpeg',
        'screen': <String, dynamic>{'w': 2048, 'h': 1280},
        'stream': <String, dynamic>{'fps': 60},
        'audio': false,
        'screens': 1,
        'version': '0.2.0',
        'ip': '192.168.31.150',
        'capture': 'mss',
        'max_fps': 30,
        'auto_lock': false,
        'power': <String>['lock'],
        'privacy': 'off',
        'privacy_engine': 'overlay',
        'file': true,
        'receive_dir': '/tmp',
        'cursor': 'unsupported',
        'mic': false,
      }));
      ws.add(jsonEncode(<String, dynamic>{
        'p': 'screens',
        'current': 0,
        'list': <Map<String, dynamic>>[
          <String, dynamic>{'id': 0, 'w': 2048, 'h': 1280, 'x': 0, 'y': 0, 'name': '内建', 'primary': true},
        ],
      }));
      // 保持连接即可：合并测试不关心画面帧
      ws.listen((Object? data) {
        if (data is String) {
          try {
            final Object? parsed = jsonDecode(data);
            if (parsed is Map<String, dynamic>) inbound.add(parsed);
          } catch (_) {}
        }
      });
      return;
    }
    await utf8.decoder.bind(req).join();
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(<String, dynamic>{
        'code': 0,
        'msg': 'ok',
        'data': <String, dynamic>{
          'signaling_server': 'ws://127.0.0.1:$port/ws/signaling',
          'token': 'room-token-merge',
          'room_id': 'room-merge',
          'ice_servers': <String, dynamic>{},
        },
      }));
    await req.response.close();
  });
  return server;
}

const DeviceInfo device = DeviceInfo(
  deviceId: 'pc-001',
  name: 'MacBook-Pro',
  platform: 'mac',
  online: true,
  isSelf: false,
  controllable: true,
  lastSeen: 0,
);

void main() {
  late HttpServer server;

  setUpAll(() async {
    HttpOverrides.global = null;
    server = await _startFake();
  });

  tearDownAll(() => server.close(force: true));

  Future<void> runPage(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'server_base': 'http://127.0.0.1:${server.port}',
      'auth_token': 'tok-merge',
      'auth_uid': '1',
      'auth_mobile': '13800138000',
      'auth_nickname': 'hoha',
      'device_uuid': 'self-001',
      'device_id': 'self-001',
      'quality_preset': '2560,85,8000',
      'stream_fps': 60,
      'stream_resolution': 'preset',
      'clipboard_sync': false,
    });
    await Settings.init();

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: const RemotePage(device: device),
    ));
    // 等 hello 落地（连接状态机推进），定量 pump 避免撞上 20 秒心跳
    for (int i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> closePage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  }

  testWidgets('宽屏：顶栏出现 鼠标/外设/文件 三组入口', (WidgetTester tester) async {
    await runPage(tester, const Size(1440, 900));
    // 锚点用「更多」这个稳定入口确认顶栏已经渲染出来
    expect(find.byTooltip('更多'), findsOneWidget);
    // 三组入口的文字（_chromePill 统一渲染，tooltip 带动态内容不好对齐）
    expect(find.text('外设'), findsOneWidget, reason: '宽屏顶栏应有外设入口');
    expect(find.text('文件'), findsOneWidget, reason: '宽屏顶栏应有文件入口');
    // 鼠标入口显示当前模式名，默认 remote 档 label 是「使用被控端鼠标」
    expect(find.text('使用被控端鼠标'), findsOneWidget, reason: '宽屏顶栏应有鼠标模式入口');
    await closePage(tester);
  });

  testWidgets('窄屏：顶栏不出现三组入口（设备名优先），但「更多」菜单里有兜底',
      (WidgetTester tester) async {
    await runPage(tester, const Size(390, 844));

    expect(find.byTooltip('外设（键位映射）'), findsNothing);
    expect(find.text('外设'), findsNothing, reason: '窄屏顶栏不应有外设入口');
    expect(find.text('文件'), findsNothing, reason: '窄屏顶栏不应有文件入口');

    // 兜底：菜单里必须还找得到
    await tester.tap(find.byTooltip('更多'));
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(find.text('鼠标模式'), findsOneWidget, reason: '窄屏菜单里应有鼠标模式兜底');
    expect(find.text('外设（键位映射）'), findsOneWidget);
    expect(find.text('文件传输'), findsOneWidget);
    await closePage(tester);
  });

  testWidgets('底栏语音按钮：被控端 hello.mic=false 时整颗按钮不出现（不是置灰假开关）',
      (WidgetTester tester) async {
    await runPage(tester, const Size(1440, 900));
    expect(find.text('语音'), findsNothing, reason: 'hello 声明不支持时按钮应整体消失');
    await closePage(tester);
  });
}
