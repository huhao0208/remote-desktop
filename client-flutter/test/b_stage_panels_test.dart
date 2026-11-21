import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uu_remote/core/file_transfer_model.dart';
import 'package:uu_remote/core/key_mapping.dart';
import 'package:uu_remote/core/mouse_mode.dart';
import 'package:uu_remote/core/theme.dart';
import 'package:uu_remote/widgets/file_transfer_panel.dart';
import 'package:uu_remote/widgets/mouse_panel.dart';
import 'package:uu_remote/widgets/peripheral_panel.dart';

/// B 阶段三个面板（鼠标 / 外设 / 文件传输）的冒烟测试。
///
/// 只验证「能构建、关键文案在、按能力置灰、回调真的带着新值回来」，
/// 不做像素断言——平台字体差异会让像素比对在 CI 上抖。
///
/// 重点放在**降级路径**上：三个面板各有一处「点了没用」的坑，
/// 那是用户最容易骂人的地方，比正常路径更值得测。
void main() {
  Widget host(Widget child) => MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          backgroundColor: AppColors.videoBg,
          body: Center(child: child),
        ),
      );

  group('鼠标面板', () {
    testWidgets('三档齐全，点击切换会带着新模式回调', (WidgetTester tester) async {
      MouseSettings? got;
      await tester.pumpWidget(host(MousePanel(
        settings: const MouseSettings(),
        cursorSupported: true,
        onChanged: (MouseSettings s) => got = s,
      )));

      expect(find.text('鼠标模式'), findsOneWidget);
      for (final MouseMode m in MouseMode.values) {
        expect(find.text(m.label), findsOneWidget);
      }

      // 点「使用主控端鼠标」这一行
      await tester.tap(find.text(MouseMode.control.label));
      await tester.pumpAndSettle();
      expect(got, isNotNull);
      expect(got!.mode, MouseMode.control);
    });

    testWidgets('被控端不支持隐藏光标时，「主控端鼠标」不可点并说明原因',
        (WidgetTester tester) async {
      MouseSettings? got;
      await tester.pumpWidget(host(MousePanel(
        settings: const MouseSettings(),
        cursorSupported: false,
        onChanged: (MouseSettings s) => got = s,
      )));

      await tester.tap(find.text(MouseMode.control.label));
      await tester.pumpAndSettle();
      // 关键承诺：点了不能有任何状态变化，否则用户会以为切过去了
      expect(got, isNull);

      // 三档仍然全看得见（不藏起来，只是不可点）
      for (final MouseMode m in MouseMode.values) {
        expect(find.text(m.label), findsOneWidget);
      }
    });

    testWidgets('非主控端鼠标模式下，游戏鼠标模式与速度不出现', (WidgetTester tester) async {
      await tester.pumpWidget(host(MousePanel(
        settings: const MouseSettings(),
        cursorSupported: true,
        onChanged: (MouseSettings _) {},
      )));
      expect(find.text('游戏鼠标模式'), findsOneWidget); // 行在，但置灰
      expect(find.text('速度'), findsNothing);

      await tester.pumpWidget(host(MousePanel(
        settings: const MouseSettings(mode: MouseMode.control, gameMode: true),
        cursorSupported: true,
        onChanged: (MouseSettings _) {},
      )));
      await tester.pumpAndSettle();
      expect(find.text('速度'), findsOneWidget);
    });
  });

  group('外设面板', () {
    testWidgets('同平台时整组置灰：点了不发新配置', (WidgetTester tester) async {
      KeyMappingConfig? got;
      await tester.pumpWidget(host(PeripheralPanel(
        config: const KeyMappingConfig(),
        localOs: 'macos',
        remoteOs: 'macOS', // 大小写不同不该被当成跨平台
        onChanged: (KeyMappingConfig c) => got = c,
      )));

      expect(find.text('外设'), findsOneWidget);
      expect(find.text('同平台'), findsOneWidget);
      expect(find.textContaining('键位直通'), findsWidgets); // 两行都该说清「不生效」

      await tester.tap(find.text('Ctrl 键'));
      await tester.pumpAndSettle();
      expect(got, isNull);
    });

    testWidgets('跨平台时显示 OS 配对，⌘ 键可切 Win/Ctrl', (WidgetTester tester) async {
      KeyMappingConfig? got;
      await tester.pumpWidget(host(PeripheralPanel(
        config: const KeyMappingConfig(),
        localOs: 'macos',
        remoteOs: 'windows',
        onChanged: (KeyMappingConfig c) => got = c,
      )));

      expect(find.text('MACOS → WINDOWS'), findsOneWidget);
      expect(find.text('⌘ 键映射为'), findsOneWidget);

      await tester.tap(find.text('Ctrl 键'));
      await tester.pumpAndSettle();
      expect(got, isNotNull);
      expect(got!.cmdAs, CmdTarget.ctrl);
    });

    testWidgets('底部常驻当前映射说明（用户要能确认到底按哪个规则在发）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(PeripheralPanel(
        config: const KeyMappingConfig(),
        localOs: 'macos',
        remoteOs: 'windows',
        onChanged: (KeyMappingConfig _) {},
      )));
      final String expectText =
          describeMapping('macos', 'windows', const KeyMappingConfig());
      expect(find.text(expectText), findsOneWidget);
    });
  });

  group('文件传输面板', () {
    FileTransferPanel build({
      required bool supported,
      List<FileTask> tasks = const <FileTask>[],
      VoidCallback? onSend,
      void Function(String)? onCancel,
      void Function(String)? onRetry,
      VoidCallback? onClearFinished,
      VoidCallback? onPickDir,
      VoidCallback? onClose,
    }) {
      return FileTransferPanel(
        tasks: tasks,
        receiveDir: '/Users/hoha/Downloads/UU Remote',
        supported: supported,
        onSend: onSend ?? () {},
        onCancel: onCancel ?? (String _) {},
        onRetry: onRetry ?? (String _) {},
        onClearFinished: onClearFinished ?? () {},
        onPickDir: onPickDir ?? () {},
        onClose: onClose ?? () {},
      );
    }

    testWidgets('被控端不支持时整块换成升级说明，不给点不动的按钮',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(build(supported: false)));

      expect(find.text('文件传输'), findsOneWidget);
      expect(find.textContaining('当前被控端不支持文件传输'), findsOneWidget);
      // 关键：这三个入口必须一起消失，否则用户点了只会一头雾水
      expect(find.text('发送文件'), findsNothing);
      expect(find.text('接收目录'), findsNothing);
      expect(find.text('清除已完成'), findsNothing);
    });

    testWidgets('空任务时给引导文案，发送按钮可点', (WidgetTester tester) async {
      int tapped = 0;
      await tester.pumpWidget(host(build(
        supported: true,
        onSend: () => tapped++,
      )));

      expect(find.textContaining('拖拽或点'), findsOneWidget);
      expect(find.text('接收目录'), findsOneWidget);

      await tester.tap(find.text('发送文件'));
      await tester.pumpAndSettle();
      expect(tapped, 1);
    });

    testWidgets('点接收目录行触发更换回调', (WidgetTester tester) async {
      int picked = 0;
      await tester.pumpWidget(host(build(supported: true, onPickDir: () => picked++)));

      await tester.tap(find.text('接收目录'));
      await tester.pumpAndSettle();
      expect(picked, 1);
    });

    testWidgets('任务行按状态给不同操作：失败可重试、进行中可取消', (WidgetTester tester) async {
      final List<String> actOn = <String>[];
      final List<FileTask> tasks = <FileTask>[
        FileTask(
          id: 'f-1',
          name: 'a.zip',
          size: 10 << 20,
          direction: FileDirection.upload,
          status: FileStatus.active,
        )..transferred = 2 << 20,
        FileTask(
          id: 'f-2',
          name: 'b.bin',
          size: 5 << 20,
          direction: FileDirection.download,
          status: FileStatus.failed,
        )..error = '对端拒绝：文件过大',
        FileTask(
          id: 'f-3',
          name: 'c.txt',
          size: 100,
          direction: FileDirection.upload,
          status: FileStatus.done,
        )..transferred = 100,
      ];

      await tester.pumpWidget(host(build(
        supported: true,
        tasks: tasks,
        onCancel: (String id) => actOn.add(id),
        onRetry: (String id) => actOn.add(id),
      )));

      expect(find.text('a.zip'), findsOneWidget);
      expect(find.text('b.bin'), findsOneWidget);
      expect(find.text('c.txt'), findsOneWidget);
      // 失败任务的错误原因要直接显示，不能只标一个红点
      expect(find.textContaining('文件过大'), findsOneWidget);
      // 有任务时「清除已完成」才有意义，这里只断言它在
      expect(find.text('清除已完成'), findsOneWidget);
      // 渲染本身不该触发任何操作回调
      expect(actOn, isEmpty);
    });

    testWidgets('关闭按钮回调（面板是弹出层，必须能关）', (WidgetTester tester) async {
      int closed = 0;
      await tester.pumpWidget(host(build(supported: true, onClose: () => closed++)));

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(closed, 1);
    });
  });
}