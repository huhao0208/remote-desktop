// 修饰键「卡键」回归测试。
//
// 场景：按住 Shift 不放，然后 ① 切走窗口（Cmd+Tab）或 ② 切到观看模式。
// 这两种情况下本地都不会再产生那次 keyUp，被控端的 Shift 就一直是按下状态——
// 用户回到远控后会发现「打字全是大写 / 选中整段」。截图完全看不出这个问题，
// 只能抓真实报文，所以这里起假信令服务端，断言发出去的帧。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uu_remote/core/models.dart';
import 'package:uu_remote/core/settings.dart';
import 'package:uu_remote/core/theme.dart';
import 'package:uu_remote/pages/remote_page.dart';

/// 假服务端收到的客户端报文（按到达顺序）。
final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

Future<HttpServer> _startFake() async {
  final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((HttpRequest req) async {
    if (req.uri.path.endsWith('/ws/signaling')) {
      final WebSocket ws = await WebSocketTransformer.upgrade(req);
      ws.listen((dynamic data) {
        try {
          sent.add(jsonDecode('$data') as Map<String, dynamic>);
        } catch (_) {
          // 非 JSON（比如二进制帧）不关心
        }
      });
      ws.add(jsonEncode(<String, dynamic>{
        'p': 'agent.hello',
        'name': 'FakePC',
        'os': 'macos',
        'media': 'jpeg',
        'screen': <String, dynamic>{'w': 1280, 'h': 800},
        'stream': <String, dynamic>{'fps': 30},
        'audio': false,
        'screens': 1,
        'version': '0.2.2',
        'auto_lock': false,
        'power': <String>['lock'],
        'privacy': 'off',
        'privacy_engine': 'overlay',
      }));
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
          'signaling_server': 'ws://127.0.0.1:${server.port}/ws/signaling',
          'token': 'tok',
          'room_id': 'room-test',
          'ice_servers': <String, dynamic>{},
        },
      }));
    await req.response.close();
  });
  return server;
}

/// 让 WebSocket 的真实 IO 有机会跑完（fake async 下不会自动 flush）。
Future<void> _flush(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Iterable<Map<String, dynamic>> _inputs(String type) =>
    sent.where((Map<String, dynamic> m) => m['p'] == 'input' && m['t'] == type);

bool _hasKeyEvent(String type, String key) =>
    _inputs(type).any((Map<String, dynamic> m) => m['k'] == key);

void main() {
  late HttpServer server;

  setUpAll(() {
    HttpOverrides.global = null; // flutter_test 默认拦网络，这里要放行到本机假服务端
  });

  setUp(() async {
    sent.clear();
    server = await _startFake();
  });

  tearDown(() async => server.close(force: true));

  const DeviceInfo device = DeviceInfo(
    deviceId: 'pc-test',
    name: 'FakePC',
    platform: 'mac',
    online: true,
    isSelf: false,
    controllable: true,
    lastSeen: 0,
  );

  Future<void> boot(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'server_base': 'http://127.0.0.1:${server.port}',
      'auth_token': 'tok',
      'auth_uid': '1',
      'auth_mobile': '13800138000',
      'auth_nickname': 'tester',
      'device_uuid': 'self-test',
      'device_id': 'self-test',
      'clipboard_sync': false,
    });
    await Settings.init();
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(fontFamily: 'NotoSansSC'),
      home: const RemotePage(device: device),
    ));
    await _flush(tester);
  }

  Future<void> teardownPage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // 页面卸了，但 socket.close() 的内部 Future 走的是 dart:io 真实 IO，
    // fake_async 的时钟推不动它；socket 不真关，pingInterval 的 20s timer 就一直挂着。
    // 只能在 runAsync 里给它真实时间，并强制断开服务端把客户端 socket 带下来。
    for (int i = 0; i < 3; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() => server.close(force: true));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump(const Duration(seconds: 35));
  }

  testWidgets('按住 Shift 后窗口失焦，补发 keyup（否则远端卡键）',
      (WidgetTester tester) async {
    await boot(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await _flush(tester);
    expect(_hasKeyEvent('keydown', 'shift'), isTrue,
        reason: '按住 Shift 应发 keydown；没发说明页面没拿到焦点');

    // 模拟 Cmd+Tab：焦点被别的窗口抢走
    tester.binding.focusManager.primaryFocus?.unfocus();
    await _flush(tester);

    expect(_hasKeyEvent('keyup', 'shift'), isTrue,
        reason: '失焦必须补发 keyup，否则被控端的 Shift 会一直按着');

    await teardownPage(tester);
  });

  testWidgets('切到观看模式：放掉修饰键 + 通知被控端 view.only',
      (WidgetTester tester) async {
    await boot(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await _flush(tester);
    expect(_hasKeyEvent('keydown', 'shift'), isTrue);

    // 走真实 UI 入口：更多 → 观看模式（输入不发送）
    await tester.tap(find.byTooltip('更多'));
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.tap(find.text('观看模式（输入不发送）'));
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await _flush(tester);

    expect(_hasKeyEvent('keyup', 'shift'), isTrue,
        reason: '进观看态前必须放掉按住的修饰键');
    expect(
      sent.any((Map<String, dynamic> m) =>
          m['p'] == 'view.only' && m['enable'] == true),
      isTrue,
      reason: '还要告知被控端只看不控，它会再清一次修饰键兜底',
    );

    // 回操控态要复位开关，否则被控端一直以为你只看不控
    await tester.tap(find.byTooltip('更多'));
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.tap(find.text('回到操控模式'));
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await _flush(tester);
    expect(
      sent.any((Map<String, dynamic> m) =>
          m['p'] == 'view.only' && m['enable'] == false),
      isTrue,
      reason: '回操控态必须发 enable:false',
    );

    await teardownPage(tester);
  });

  testWidgets('观看态不再发送任何 input（核心承诺）', (WidgetTester tester) async {
    await boot(tester);

    await tester.tap(find.byTooltip('更多'));
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.tap(find.text('观看模式（输入不发送）'));
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await _flush(tester);
    final int baseline = _inputs('move').length + _inputs('click').length;

    // 观看态下点画面：只该平移视图，不该产生远端点击
    await tester.tapAt(const Offset(700, 450));
    await tester.pump(const Duration(milliseconds: 200));
    await _flush(tester);

    expect(_inputs('move').length + _inputs('click').length, baseline,
        reason: '观看态点了画面，不应该有任何 move/click 发到被控端');

    await teardownPage(tester);
  });
}
