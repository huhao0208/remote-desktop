import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uu_remote/core/theme.dart';
import 'package:uu_remote/widgets/ui_kit.dart';

/// UI 组件层冒烟测试：保证设计系统组件能正常构建、状态切换不崩。
/// 不做像素断言（避免平台字体差异导致 CI 抖动），只验证结构存在。
void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('Pill / StatusDot / HudChip 能渲染文本', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: const <Widget>[
          Pill(text: '可远控', color: AppColors.accent, filled: true),
          StatusDot(color: AppColors.online, pulse: true),
          HudChip(text: '30 fps', icon: Icons.speed),
        ],
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('可远控'), findsOneWidget);
    expect(find.text('30 fps'), findsOneWidget);
  });

  testWidgets('AppCard 可点击并触发回调', (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(wrap(
      AppCard(
        onTap: () => taps++,
        child: const Text('设备 A'),
      ),
    ));
    await tester.tap(find.text('设备 A'));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('EmptyState 展示标题与说明', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(
      const EmptyState(icon: Icons.devices_other, title: '没有设备', message: '先启动被控端'),
    ));
    expect(find.text('没有设备'), findsOneWidget);
    expect(find.text('先启动被控端'), findsOneWidget);
  });

  testWidgets('GlassPanel 内容可见', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(
      const GlassPanel(child: Text('工具栏')),
    ));
    expect(find.text('工具栏'), findsOneWidget);
  });
}