import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../core/file_transfer_model.dart';
import '../core/theme.dart';

/// 文件传输面板（协议 v3 §2）。
///
/// 纯展示 + 回调：选文件、取消、重试、换接收目录、清空都交给调用方，
/// 这里不碰 socket、不读写磁盘。面板**不自带背景和阴影**，
/// 外层放进 `GlassPanel` 或任意 `AppColors.videoChrome` 容器即可。
///
/// 宽 360、最高 420；任务多时只有中间列表滚动，标题与汇总行常驻。
class FileTransferPanel extends StatelessWidget {
  const FileTransferPanel({
    super.key,
    required this.tasks,
    required this.receiveDir,
    required this.supported,
    required this.onSend,
    required this.onCancel,
    required this.onRetry,
    required this.onClearFinished,
    required this.onPickDir,
    required this.onClose,
  });

  final List<FileTask> tasks;

  /// 本机接收目录。可能很长，面板内做中间省略，完整值挂在 tooltip 上。
  final String receiveDir;

  /// 被控端不支持文件传输时，整块换成升级说明，不给点不动的空按钮。
  final bool supported;

  final VoidCallback onSend;
  final void Function(String id) onCancel;
  final void Function(String id) onRetry;
  final VoidCallback onClearFinished;
  final VoidCallback onPickDir;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(),
            if (!supported)
              _unsupportedBody()
            else ...<Widget>[
              Flexible(child: _body()),
              _footer(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text(
                '文件传输',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.videoText),
              ),
              const Spacer(),
              if (supported) ...<Widget>[
                _sendButton(),
                const SizedBox(width: 4),
              ],
              InkWell(
                onTap: onClose,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 16, color: AppColors.videoMuted),
                ),
              ),
            ],
          ),
          if (supported) _receiveDirRow(),
        ],
      ),
    );
  }

  Widget _sendButton() {
    return TextButton.icon(
      onPressed: onSend,
      icon: const Icon(Icons.add, size: 13, color: Colors.white),
      label: const Text('发送文件'),
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: AppColors.accent,
        minimumSize: const Size(0, 24),
        padding: const EdgeInsets.symmetric(horizontal: 9),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
        textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _receiveDirRow() {
    final String shown = _middleEllipsis(receiveDir, 32);
    return Tooltip(
      message: '接收目录：$receiveDir\n点击更换',
      child: InkWell(
        onTap: onPickDir,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          child: Row(
            children: <Widget>[
              const Icon(Icons.folder_open_outlined, size: 12, color: AppColors.videoMuted),
              const SizedBox(width: 5),
              const Text('接收目录', style: TextStyle(fontSize: 10.5, color: AppColors.videoMuted)),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  shown,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: AppColors.videoText.withValues(alpha: 0.78),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.edit_outlined, size: 11, color: AppColors.videoMuted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (tasks.isEmpty) return _emptyState();
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      itemCount: tasks.length,
      itemBuilder: (BuildContext context, int i) => _taskRow(tasks[i]),
    );
  }

  Widget _emptyState() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 28, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.upload_file_outlined, size: 26, color: AppColors.faint),
          SizedBox(height: AppSpace.sm),
          Text(
            '拖拽或点『发送文件』，把本机文件发到被控端',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, height: 1.5, color: AppColors.videoMuted),
          ),
        ],
      ),
    );
  }

  Widget _taskRow(FileTask task) {
    final _TaskLook look = _taskLook(task);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(look.icon, size: 16, color: look.iconColor),
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        task.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: AppColors.videoText),
                      ),
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 132),
                      child: Text(
                        task.statusText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 10.5, color: look.statusColor),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: task.progress,
                    minHeight: 3,
                    backgroundColor: AppColors.videoChromeBorder,
                    valueColor: AlwaysStoppedAnimation<Color>(look.barColor),
                  ),
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          task.progressText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: AppColors.videoMuted,
                            fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                    // 只有进行中能取消、只有失败能重试：其余状态给按钮也只是摆设
                    if (task.running) _actionButton('取消', AppColors.videoMuted, () => onCancel(task.id)),
                    if (task.status == FileStatus.failed)
                      _actionButton('重试', AppColors.accent, () => onRetry(task.id)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton(String label, Color color, VoidCallback onTap) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: color,
        minimumSize: const Size(0, 20),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
      ),
      child: Text(label),
    );
  }

  Widget _footer() {
    final int receiving = tasks
        .where((FileTask t) => t.direction == FileDirection.download && t.status == FileStatus.active)
        .length;
    final int waiting = tasks
        .where((FileTask t) => t.direction == FileDirection.download && t.status == FileStatus.pending)
        .length;
    final int sending = tasks
        .where((FileTask t) => t.direction == FileDirection.upload && t.running)
        .length;
    final int done = tasks.where((FileTask t) => t.status == FileStatus.done).length;
    final bool canClear = tasks.any((FileTask t) => t.finished);

    final List<String> parts = <String>[
      '接收中 $receiving',
      if (waiting > 0) '待接收 $waiting',
      if (sending > 0) '发送中 $sending',
      '已完成 $done',
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 10, 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.videoChromeBorder)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              parts.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                color: AppColors.videoMuted,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          TextButton(
            onPressed: canClear ? onClearFinished : null,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.videoMuted,
              disabledForegroundColor: AppColors.videoMuted.withValues(alpha: 0.4),
              minimumSize: const Size(0, 24),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 11),
            ),
            child: const Text('清除已完成'),
          ),
        ],
      ),
    );
  }

  Widget _unsupportedBody() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.warn.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: const Text(
              '当前被控端不支持文件传输：它的版本还没有这套协议。',
              style: TextStyle(fontSize: 11.5, height: 1.45, color: AppColors.warn),
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          const Text(
            '请在被控端升级到最新版本后重新连接，再从这里互传文件。'
            '本机不需要做任何改动。',
            style: TextStyle(fontSize: 10.5, height: 1.5, color: AppColors.videoMuted),
          ),
        ],
      ),
    );
  }
}

/// 一行任务要用的图标与配色，按状态和扩展名一次算好。
class _TaskLook {
  const _TaskLook({
    required this.icon,
    required this.iconColor,
    required this.statusColor,
    required this.barColor,
  });

  final IconData icon;
  final Color iconColor;
  final Color statusColor;
  final Color barColor;
}

_TaskLook _taskLook(FileTask task) {
  final _FileKind kind = _fileKindOf(task.name);
  switch (task.status) {
    case FileStatus.done:
      return _TaskLook(
        icon: kind.icon,
        iconColor: kind.color,
        statusColor: AppColors.online,
        barColor: AppColors.online,
      );
    case FileStatus.failed:
      return _TaskLook(
        icon: kind.icon,
        iconColor: kind.color,
        statusColor: AppColors.danger,
        barColor: AppColors.danger,
      );
    case FileStatus.canceled:
      return _TaskLook(
        icon: kind.icon,
        iconColor: kind.color.withValues(alpha: 0.55),
        statusColor: AppColors.videoMuted.withValues(alpha: 0.75),
        barColor: AppColors.videoMuted.withValues(alpha: 0.55),
      );
    case FileStatus.pending:
    case FileStatus.active:
      return _TaskLook(
        icon: kind.icon,
        iconColor: kind.color,
        statusColor: AppColors.videoMuted,
        barColor: AppColors.accent,
      );
  }
}

class _FileKind {
  const _FileKind(this.icon, this.color);

  final IconData icon;
  final Color color;
}

const Set<String> _imageExts = <String>{'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'heic', 'tif', 'tiff'};
const Set<String> _videoExts = <String>{'mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v', 'flv'};
const Set<String> _audioExts = <String>{'mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'aiff'};
const Set<String> _archiveExts = <String>{'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'dmg', 'iso'};
const Set<String> _docExts = <String>{
  'pdf', 'doc', 'docx', 'txt', 'md', 'rtf', 'xls', 'xlsx', 'csv', 'ppt', 'pptx', 'pages', 'numbers', 'key',
};
const Set<String> _codeExts = <String>{
  'dart', 'js', 'ts', 'tsx', 'jsx', 'py', 'go', 'rs', 'java', 'kt', 'c', 'h', 'cpp', 'sh', 'json', 'yaml', 'yml', 'xml', 'html', 'css',
};

/// 按扩展名粗分六类：图标一眼能分出「图 / 视 / 音 / 包 / 文档 / 代码」。
_FileKind _fileKindOf(String name) {
  final int dot = name.lastIndexOf('.');
  final String ext = (dot >= 0 && dot < name.length - 1) ? name.substring(dot + 1).toLowerCase() : '';
  if (_imageExts.contains(ext)) return const _FileKind(Icons.image_outlined, AppColors.accent);
  if (_videoExts.contains(ext)) return const _FileKind(Icons.movie_outlined, AppColors.info);
  if (_audioExts.contains(ext)) return const _FileKind(Icons.audiotrack_outlined, AppColors.warn);
  if (_archiveExts.contains(ext)) return const _FileKind(Icons.folder_zip_outlined, AppColors.videoMuted);
  if (_docExts.contains(ext)) return const _FileKind(Icons.description_outlined, AppColors.videoMuted);
  if (_codeExts.contains(ext)) return const _FileKind(Icons.code, AppColors.online);
  return const _FileKind(Icons.insert_drive_file_outlined, AppColors.videoMuted);
}

/// 长路径保留头尾、中间用省略号：`C:\Users\…\Downloads`。
String _middleEllipsis(String text, int maxChars) {
  if (text.length <= maxChars) return text;
  final int head = (maxChars - 1) ~/ 2;
  final int tail = maxChars - 1 - head;
  return '${text.substring(0, head)}…${text.substring(text.length - tail)}';
}

/// 弹出文件传输面板。放右侧靠上，与其它面板同一视觉位置。
///
/// 用 `showGeneralDialog` 而不是 dialog：传输中面板要能被点到别处收起，
/// 但**不能**因为收起就中断传输——服务本身活在页面生命周期里，
/// 面板只是它的一个视图。
///
/// [revision] 必须传服务自己的 `ValueNotifier`，不能只传一份 `tasks` 快照：
/// dialog 是**独立路由**，宿主页面的 `setState` 重建不到它，只传快照的话
/// 面板从头到尾都是打开那一瞬间的样子——进度条不动、新任务不出现。
Future<void> showFileTransferPanel(
  BuildContext context, {
  required List<FileTask> tasks,
  required ValueListenable<int> revision,
  required String receiveDir,
  required bool supported,
  required ValueChanged<FileTask> onCancel,
  required ValueChanged<FileTask> onRetry,
  required VoidCallback onSend,
  required VoidCallback onClearFinished,
  required VoidCallback onPickDir,
  required ValueChanged<bool> onVisibility, // true=打开 false=关闭
}) {
  onVisibility(true);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '文件传输',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (BuildContext ctx, Animation<double> a, Animation<double> b) =>
        const SizedBox.shrink(),
    transitionBuilder:
        (BuildContext ctx, Animation<double> anim, Animation<double> b, Widget child) {
      return FadeTransition(
        opacity: anim,
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 52, right: 10, bottom: 56),
            child: ValueListenableBuilder<int>(
              valueListenable: revision,
              builder: (BuildContext _, int _, Widget? _) => FileTransferPanel(
                tasks: tasks,
                receiveDir: receiveDir,
                supported: supported,
                onSend: onSend,
                // 用 firstWhereOrNull 的语义：任务可能已被「清除已完成」移走，
                // 此时用户正好点到这一行不该抛异常炸掉面板。
                onCancel: (String id) {
                  for (final FileTask t in tasks) {
                    if (t.id == id) return onCancel(t);
                  }
                },
                onRetry: (String id) {
                  for (final FileTask t in tasks) {
                    if (t.id == id) return onRetry(t);
                  }
                },
                onClearFinished: onClearFinished,
                onPickDir: onPickDir,
                onClose: () => Navigator.of(ctx).maybePop(),
              ),
            ),
          ),
        ),
      );
    },
  ).whenComplete(() => onVisibility(false));
}
