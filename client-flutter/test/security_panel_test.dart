import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uu_remote/core/security.dart';
import 'package:uu_remote/core/theme.dart';
import 'package:uu_remote/widgets/power_panel.dart';
import 'package:uu_remote/widgets/security_panel.dart';

/// 安全 / 电源两个下拉面板的冒烟测试。
///
/// 只验证「能构建、关键文案在、按能力置灰」，不做像素断言
/// （平台字体差异会让像素比对在 CI 上抖）。
void main() {
  Widget host(Widget Function(BuildContext) onTap) => MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: Builder(builder: onTap)),
      );

  testWidgets('安全面板：引擎不支持时整组置灰并说明原因', (WidgetTester tester) async {
    final ValueNotifier<SecurityState> vn =
        ValueNotifier<SecurityState>(const SecurityState(engine: 'unsupported'));
    addTearDown(vn.dispose);

    await tester.pumpWidget(host((BuildContext ctx) => TextButton(
          onPressed: () => showSecurityPanel(
            ctx,
            state: vn,
            onPrivacy: (PrivacyMode m) {},
            onAutoLock: (bool v) {},
            onMute: (bool v) {},
          ),
          child: const Text('open'),
        )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('防窥模式'), findsOneWidget);
    expect(find.text('黑屏防护'), findsOneWidget);
    expect(find.textContaining('无法做防窥'), findsOneWidget);
    // 自动锁屏 / 被控静音仍在（不因防窥不可用而一起消失）
    expect(find.text('自动锁屏'), findsOneWidget);
    expect(find.text('被控静音'), findsOneWidget);
    // 未开任何保护 → 需关注
    expect(find.text('需关注'), findsOneWidget);
  });

  testWidgets('安全面板：收到外部回执后回退选中态', (WidgetTester tester) async {
    final ValueNotifier<SecurityState> vn =
        ValueNotifier<SecurityState>(const SecurityState(engine: 'overlay'));
    addTearDown(vn.dispose);

    await tester.pumpWidget(host((BuildContext ctx) => TextButton(
          onPressed: () => showSecurityPanel(
            ctx,
            state: vn,
            onPrivacy: (PrivacyMode m) {},
            onAutoLock: (bool v) {},
            onMute: (bool v) {},
          ),
          child: const Text('open'),
        )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 面板打开后，被控端拒绝：状态回到 off 且带错误
    vn.value = const SecurityState(
      engine: 'overlay',
      error: '遮罩窗启动失败',
    );
    await tester.pumpAndSettle();
    expect(find.text('遮罩窗启动失败'), findsOneWidget);
  });

  testWidgets('电源面板：不支持的项置灰，支持项可点', (WidgetTester tester) async {
    final List<PowerAction> fired = <PowerAction>[];
    await tester.pumpWidget(host((BuildContext ctx) => TextButton(
          onPressed: () => showPowerPanel(
            ctx,
            supports: (String action) => action != 'taskmgr',
            onAction: fired.add,
          ),
          child: const Text('open'),
        )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('锁屏'), findsOneWidget);
    expect(find.text('关机'), findsOneWidget);
    expect(find.text('当前被控端不支持'), findsOneWidget);

    // 锁屏没有倒计时，点一下立刻回调
    await tester.tap(find.text('锁屏'));
    await tester.pumpAndSettle();
    expect(fired, <PowerAction>[PowerAction.lock]);
  });

  testWidgets('电源面板：关机要先确认，取消则不发送', (WidgetTester tester) async {
    final List<PowerAction> fired = <PowerAction>[];
    await tester.pumpWidget(host((BuildContext ctx) => TextButton(
          onPressed: () => showPowerPanel(
            ctx,
            supports: (String action) => true,
            onAction: fired.add,
          ),
          child: const Text('open'),
        )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('关机'));
    await tester.pumpAndSettle();
    expect(find.text('关机被控端？'), findsOneWidget);
    expect(fired, isEmpty);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(fired, isEmpty);
  });

  testWidgets('电源面板：确认后按动作回调', (WidgetTester tester) async {
    final List<PowerAction> fired = <PowerAction>[];
    await tester.pumpWidget(host((BuildContext ctx) => TextButton(
          onPressed: () => showPowerPanel(
            ctx,
            supports: (String action) => true,
            onAction: fired.add,
          ),
          child: const Text('open'),
        )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('关机'));
    await tester.pumpAndSettle();
    // 确认按钮是弹窗里的那个「关机」（TextButton）
    await tester.tap(find.widgetWithText(TextButton, '关机'));
    await tester.pumpAndSettle();
    expect(fired, <PowerAction>[PowerAction.shutdown]);
  });
}
