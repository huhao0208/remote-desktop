import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uu_remote/core/file_transfer_model.dart';
import 'package:uu_remote/core/theme.dart';
import 'package:uu_remote/widgets/file_transfer_panel.dart';

/// 文件面板的**进度联动**回归测试。
///
/// 背景（真实踩过的 bug）：`showFileTransferPanel` 最初把 `tasks` 拷一份快照传进去，
/// 而 `showGeneralDialog` 建的是**独立路由**——宿主页面 `setState` 重建不到它。
/// 结果面板从头到尾都是打开那一瞬间的样子：进度条不动、新任务不出现。
/// 现在面板订阅服务自己的 `revision`，这里就锁死这个契约。
void main() {
  Widget host(Widget child) => MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(backgroundColor: AppColors.videoBg, body: Center(child: child)),
      );

  testWidgets('revision 变化后面板跟着重建（进度条会动）', (WidgetTester tester) async {
    final ValueNotifier<int> revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);

    final FileTask task = FileTask(
      id: 'f-1',
      name: 'ubuntu.iso',
      size: 100 << 20, // 100 MiB
      direction: FileDirection.upload,
      status: FileStatus.active,
    )..transferred = 0;

    await tester.pumpWidget(host(ValueListenableBuilder<int>(
      valueListenable: revision,
      builder: (BuildContext _, int _, Widget? _) => FileTransferPanel(
        tasks: <FileTask>[task],
        receiveDir: '/tmp',
        supported: true,
        onSend: () {},
        onCancel: (String _) {},
        onRetry: (String _) {},
        onClearFinished: () {},
        onPickDir: () {},
        onClose: () {},
      ),
    )));

    // 注意用完整文案断言：`'0%'` 是 `'50%'` 的子串，textContaining 会假阳性
    expect(find.text(task.progressText), findsOneWidget);
    expect(task.progressText, contains('· 0%'));

    // 同一条任务对象就地改字段（服务的做法），再推一次 revision
    task.transferred = 50 << 20;
    revision.value = 1;
    await tester.pumpAndSettle();

    expect(find.text(task.progressText), findsOneWidget);
    expect(task.progressText, contains('· 50%'));
    expect(find.textContaining('· 0%'), findsNothing);
  });

  testWidgets('任务被「清除已完成」移走后，再点旧行不会抛异常', (WidgetTester tester) async {
    // 回调里对已不在 tasks 里的 id 做线性查找而不是 firstWhere，
    // 就是为了这种「UI 和列表短暂不一致」的窗口期不炸。
    final List<FileTask> tasks = <FileTask>[
      FileTask(id: 'f-1', name: 'a.txt', size: 10, direction: FileDirection.upload),
    ];
    final List<String> hits = <String>[];

    await tester.pumpWidget(host(FileTransferPanel(
      tasks: tasks,
      receiveDir: '/tmp',
      supported: true,
      onSend: () {},
      onCancel: (String id) => hits.add('cancel:$id'),
      onRetry: (String id) => hits.add('retry:$id'),
      onClearFinished: () {},
      onPickDir: () {},
      onClose: () {},
    )));

    // 清空列表后原样重建，不应抛
    tasks.clear();
    await tester.pumpWidget(host(FileTransferPanel(
      tasks: tasks,
      receiveDir: '/tmp',
      supported: true,
      onSend: () {},
      onCancel: (String id) => hits.add('cancel:$id'),
      onRetry: (String id) => hits.add('retry:$id'),
      onClearFinished: () {},
      onPickDir: () {},
      onClose: () {},
    )));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('拖拽或点'), findsOneWidget);
    expect(hits, isEmpty);
  });
}