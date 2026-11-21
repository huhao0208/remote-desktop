// 远控页 UI 预览（不参与默认测试，只为人工核对视觉）。
//
// 起一个假服务端（HTTP 回房间配置 + WS 发 hello/JPEG 帧），把 RemotePage 渲染成 PNG。
// 跑：flutter test --tags preview test/_preview_remote_test.dart
@Tags(<String>['preview'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uu_remote/core/models.dart';
import 'package:uu_remote/core/settings.dart';
import 'package:uu_remote/core/theme.dart';
import 'package:uu_remote/pages/remote_page.dart';

const String outDir = '/tmp/ui_preview';
const String desktopJpg = '/tmp/ui_preview/fake_desktop.jpg';

Uint8List? _frame;

/// 假服务器收到的客户端消息。断言用：观看模式的核心承诺是
/// 「输入不会发给被控端」，这一点只能靠抓报文验证，看截图看不出来。
final List<Map<String, dynamic>> inbound = <Map<String, dynamic>>[];

/// 帧格式（`jpeg_transport.dart`）：`FRM1` + 8 字节大端时间戳 + JPEG。
Uint8List _wrapFrame(Uint8List jpeg) {
  final ByteData head = ByteData(12);
  head.setUint8(0, 0x46); // F
  head.setUint8(1, 0x52); // R
  head.setUint8(2, 0x4D); // M
  head.setUint8(3, 0x31); // 1
  head.setUint64(4, DateTime.now().millisecondsSinceEpoch, Endian.big);
  return Uint8List.fromList(<int>[...head.buffer.asUint8List(), ...jpeg]);
}

Future<HttpServer> _startFake() async {
  final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final int port = server.port;

  server.listen((HttpRequest req) async {
    if (req.uri.path.endsWith('/ws/signaling')) {
      final WebSocket ws = await WebSocketTransformer.upgrade(req);
      // 1) 先发 hello：JPEG 通路，双屏，带安全能力面（面板才有内容）
      ws.add(jsonEncode(<String, dynamic>{
        'p': 'agent.hello',
        'name': 'MacBook-Pro',
        'os': 'macos',
        'media': 'jpeg',
        'screen': <String, dynamic>{'w': 2048, 'h': 1280},
        'stream': <String, dynamic>{'fps': 60},
        'audio': true,
        'screens': 2,
        'version': '0.2.0',
        'ip': '192.168.31.150',
        'capture': 'mss（screencapture 兜底）',
        'max_fps': 30,
        'auto_lock': true,
        'power': <String>['lock', 'reboot', 'shutdown', 'taskmgr'],
        'privacy': 'off',
        'privacy_engine': 'overlay',
      }));
      // 2) 屏幕列表（顶栏切屏入口）
      ws.add(jsonEncode(<String, dynamic>{
        'p': 'screens',
        'current': 0,
        'list': <Map<String, dynamic>>[
          <String, dynamic>{'id': 0, 'w': 2048, 'h': 1280, 'x': 0, 'y': 0, 'name': '内建', 'primary': true},
          <String, dynamic>{'id': 1, 'w': 1920, 'h': 1080, 'x': 2048, 'y': 0, 'name': '外接', 'primary': false},
        ],
      }));
      // 3) 持续推帧
      final Timer t = Timer.periodic(const Duration(milliseconds: 66), (Timer timer) {
        if (_frame == null) return;
        try {
          ws.add(_wrapFrame(_frame!));
        } catch (_) {
          timer.cancel();
        }
      });
      ws.listen((Object? data) {
        // 记下来供断言用（「观看态不发送输入」这类行为只能靠抓报文验证）
        if (data is String) {
          try {
            final Object? parsed = jsonDecode(data);
            if (parsed is Map<String, dynamic>) inbound.add(parsed);
          } catch (_) {
            // 二进制帧/非 JSON 一律忽略
          }
        }
      }, onDone: () => t.cancel(), onError: (_) => t.cancel());
      return;
    }

    // 其余一律当 joinRoom：返回房间配置
    await utf8.decoder.bind(req).join();
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(<String, dynamic>{
        'code': 0,
        'msg': 'ok',
        'data': <String, dynamic>{
          'signaling_server': 'ws://127.0.0.1:$port/ws/signaling',
          'token': 'room-token-preview',
          'room_id': 'room-preview',
          'ice_servers': <String, dynamic>{},
        },
      }));
    await req.response.close();
  });
  return server;
}

Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final File file = File(path);
    if (!file.existsSync()) {
      stdout.writeln('[font] 缺 $path');
      return;
    }
    final ByteData data = file.readAsBytesSync().buffer.asByteData();
    await (FontLoader(family)..addFont(Future<ByteData>.value(data))).load();
  }

  // 测试环境默认字体是 Ahem（全方块），必须注入真实中文与图标字体
  const String cjk = '/Library/Fonts/Arial Unicode.ttf';
  for (final String family in <String>[
    'Roboto', 'Roboto Medium', 'NotoSansSC', '.SF UI Text', '.AppleSystemUIFont',
    'Segoe UI', 'Ubuntu', 'Noto Sans', 'Arial Unicode MS', 'sans-serif',
  ]) {
    await load(family, cjk);
  }
  await load('MaterialIcons',
      '/Users/hoha/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _shot(WidgetTester tester, GlobalKey key, String name) async {
  // 这里**不要**再 pump：pump 会让 `Image.memory` 重新走解码，而 fake async
  // 里解码永远完不成，截出来就是纯黑。画面刷新交给调用方的 `_settle`。
  await tester.runAsync(() async {
    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
    final ByteData? bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(outDir).createSync(recursive: true);
    File('$outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    stdout.writeln('[shot] $outDir/$name.png');
  });
}

void main() {
  late HttpServer server;

  setUpAll(() async {
    Directory(outDir).createSync(recursive: true);
    HttpOverrides.global = null; // flutter_test 默认拦网络，预览要放行
    _frame = File(desktopJpg).existsSync() ? File(desktopJpg).readAsBytesSync() : null;
    if (_frame == null) stdout.writeln('[warn] 缺 $desktopJpg，画面区会是空的');
    server = await _startFake();
    await _loadFonts();
  });

  tearDownAll(() async => server.close(force: true));

  Widget host(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(fontFamily: 'NotoSansSC'),
        home: child,
      );

  const DeviceInfo device = DeviceInfo(
    deviceId: 'pc-001',
    name: 'MacBook-Pro',
    platform: 'mac',
    online: true,
    isSelf: false,
    controllable: true,
    lastSeen: 0,
  );

  Future<void> run(
    WidgetTester tester,
    Size size,
    String name, {
    Future<void> Function(WidgetTester tester, GlobalKey key)? afterSettle,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'server_base': 'http://127.0.0.1:${server.port}',
      'auth_token': 'tok-preview',
      'auth_uid': '1',
      'auth_mobile': '13800138000',
      'auth_nickname': 'hoha',
      'device_uuid': 'self-001',
      'device_id': 'self-001',
      'quality_preset': '2560,85,8000',
      'stream_fps': 60,
      'stream_resolution': 'preset',
      'clipboard_sync': true,
    });
    await Settings.init();

    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: key, child: host(const RemotePage(device: device))));
    await _settle(tester);
    if (afterSettle != null) await afterSettle(tester, key);
    await _shot(tester, key, name);
    await tester.pumpWidget(const SizedBox()); // 卸载，取消内部 Timer
    // 信令心跳/重连是 20 秒周期定时器，卸载后仍留在 fake_async 队列里，
    // 不排空会在 teardown 报 Pending timers（纯噪音，掩盖真正的失败）。
    await tester.pump(const Duration(seconds: 30));
  }

  testWidgets('preview remote desktop', (WidgetTester tester) async {
    await run(tester, const Size(1440, 900), '10-remote-desktop');
  });

  testWidgets('preview remote narrow', (WidgetTester tester) async {
    await run(tester, const Size(390, 844), '11-remote-phone');
  });

  testWidgets('preview remote hud', (WidgetTester tester) async {
    await run(
      tester,
      const Size(1440, 900),
      '12-remote-hud',
      afterSettle: (WidgetTester tester, GlobalKey key) async {
        // 用定量 pump 而不是 pumpAndSettle：后者会把时间推进好几秒，
        // 触发「首屏 5 秒后自动收起工具栏」，截出来就只剩画面了。
        // 关键：PopupMenu 的入场动画必须分多帧 pump 到 paint 完成，
        // 单次 pump 后菜单项还是 NEEDS-PAINT，tap 会打空（命中测试失败）。
        await tester.tap(find.byTooltip('更多'));
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 80));
        }
        expect(find.text('网络状态：隐藏'), findsOneWidget, reason: '菜单应已展开');
        await tester.tap(find.text('网络状态：隐藏'));
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 80));
        }
        expect(find.text('网络状态：隐藏'), findsNothing, reason: '菜单应已关闭');
        await _settle(tester);
      },
    );
  });

  testWidgets('preview remote exit dialog', (WidgetTester tester) async {
    await run(
      tester,
      const Size(1440, 900),
      '13-remote-exit',
      afterSettle: (WidgetTester tester, GlobalKey key) async {
        await tester.tap(find.byTooltip('断开并返回设备列表'));
        // 同样要分帧 pump：单帧推进会停在 FadeScaleTransition 的中间，
        // 截出来是个半透明对话框（看起来像主题没设底色）。
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 80));
        }
        expect(find.text('结束远程控制？'), findsOneWidget);
        await _settle(tester);
      },
    );
  });

  testWidgets('preview remote view mode', (WidgetTester tester) async {
    await run(
      tester,
      const Size(1440, 900),
      '14-remote-view',
      afterSettle: (WidgetTester tester, GlobalKey key) async {
        await tester.tap(find.byTooltip('更多'));
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 80));
        }
        await tester.tap(find.text('观看模式（输入不发送）'));
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 80));
        }
        expect(find.text('退出观看'), findsOneWidget, reason: '观看工具条应出现');
        await _settle(tester);
      },
    );
  });

  testWidgets('preview remote annotation', (WidgetTester tester) async {
    await run(
      tester,
      const Size(1440, 900),
      '15-remote-annotation',
      afterSettle: (WidgetTester tester, GlobalKey key) async {
        await tester.tap(find.byTooltip('更多'));
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 80));
        }
        await tester.tap(find.text('批注（只在本机可见）'));
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 80));
        }
        // 画一笔：从画面中部往右下拖
        final Offset start = tester.getCenter(find.byType(Scaffold)) - const Offset(180, 60);
        final TestGesture gesture = await tester.startGesture(start);
        for (int i = 0; i < 12; i++) {
          await gesture.moveBy(const Offset(24, 12));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('批注'), findsWidgets, reason: '批注工具条应出现');
        await _settle(tester);
      },
    );
  });

  testWidgets('view mode blocks input', (WidgetTester tester) async {
    await run(
      tester,
      const Size(1440, 900),
      '16-view-noinput',
      afterSettle: (WidgetTester tester, GlobalKey key) async {
        // 对照：操控态下拖一下鼠标，必须产生 input 消息
        inbound.clear();
        final TestGesture ctrl = await tester.startGesture(const Offset(700, 420));
        await ctrl.moveBy(const Offset(40, 20));
        await tester.pump(const Duration(milliseconds: 16));
        await ctrl.up();
        await tester.pump(const Duration(milliseconds: 16));
        // WS 的 flush 在真实事件循环里，fake async 的 pump 不会把报文送到服务器
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
        expect(
          inbound.where((Map<String, dynamic> m) => m['p'] == 'input'),
          isNotEmpty,
          reason: '操控态应当把鼠标事件发给被控端（对照组，否则下面的断言可能是假通过）',
        );

        // 切到观看模式
        await tester.tap(find.byTooltip('更多'));
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 80));
        }
        await tester.tap(find.text('观看模式（输入不发送）'));
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 80));
        }
        expect(find.text('退出观看'), findsOneWidget);

        // 观看态再拖同样的动作，一条 input 都不该有
        inbound.clear();
        final TestGesture view = await tester.startGesture(const Offset(700, 420));
        await view.moveBy(const Offset(60, 30));
        await tester.pump(const Duration(milliseconds: 16));
        await view.up();
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
        expect(
          inbound.where((Map<String, dynamic> m) => m['p'] == 'input'),
          isEmpty,
          reason: '观看模式承诺输入不发给被控端，这里出现 input 就是功能失效',
        );
        await _settle(tester);
      },
    );
  });
}
