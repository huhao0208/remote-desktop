/// 文件传输的共享数据模型（协议 v3 §2）。
///
/// 这里只放**纯数据 + 纯函数**：UI（`widgets/file_transfer_panel.dart`）、
/// 协议层（`core/file_transfer.dart`）、页面接线三方都用它，
/// 各自文件互不重叠，避免并行改动打架。
library;

import 'dart:math' as math;

/// 传输方向以「谁发起」为准，不靠 `dir` 字段猜（协议 v3 §2 规则 1）。
enum FileDirection { upload, download }

enum FileStatus { pending, active, done, failed, canceled }

/// 单块原始字节数。32KB：base64 后约 43.7KB，不至于把同一条 WS 上的
/// `input` 事件堵在队头（详见协议 v3 §1）。
const int kFileChunkBytes = 32 * 1024;

/// 单文件上限。超过直接 `file.reject too_large`，不做「先传后拒」。
const int kFileMaxBytes = 4 << 30; // 4 GiB

/// 进度回调节流：≥1MiB 或 ≥500ms 才发一次（协议 v3 §2 规则 7）。
const int kFileProgressBytes = 1 << 20;
const Duration kFileProgressInterval = Duration(milliseconds: 500);

/// 一条传输任务的进度快照。字段可变——UI 每帧读同一对象，
/// 靠 `FileTransferService.revision` 触发重绘，不做对象拷贝。
class FileTask {
  FileTask({
    required this.id,
    required this.name,
    required this.size,
    required this.direction,
    this.savePath,
    this.status = FileStatus.pending,
  });

  final String id;

  /// 展示名（只留 basename，见 [safeFileName]）。
  final String name;

  /// 总字节数（`file.accept` 回的 size 可能被 Agent 修正过，以它为准）。
  final int size;

  final FileDirection direction;

  /// 落盘路径：上传是「被控端真实路径」，下载是「本机保存路径」。
  String? savePath;

  String? error;

  /// 已传字节数（上传＝已发出，下载＝已写入）。
  int transferred = 0;

  FileStatus status;

  bool get finished =>
      status == FileStatus.done || status == FileStatus.failed || status == FileStatus.canceled;

  bool get running => status == FileStatus.active || status == FileStatus.pending;

  /// 0..1。`size<=0` 时只有 `done` 视为完成，避免「0 字节文件显示 100%」。
  double get progress {
    if (size <= 0) return status == FileStatus.done ? 1 : 0;
    return (transferred / size).clamp(0.0, 1.0);
  }

  String get sizeText => formatBytes(size);

  /// 「3.2 MB / 10.0 MB · 32%」。下载方向加箭头，一眼看出方向。
  String get progressText {
    final String arrow = direction == FileDirection.upload ? '↑' : '↓';
    final String done = formatBytes(transferred);
    final String pct = '${(progress * 100).round()}%';
    if (direction == FileDirection.upload) return '$arrow $done / $sizeText · $pct';
    return '$arrow $sizeText · $pct';
  }

  /// 失败原因已本地化，UI 直接显示。
  String get statusText {
    switch (status) {
      case FileStatus.pending:
        return direction == FileDirection.upload ? '排队中' : '准备接收';
      case FileStatus.active:
        return direction == FileDirection.upload ? '发送中' : '接收中';
      case FileStatus.done:
        return direction == FileDirection.upload ? '已发送' : '已接收';
      case FileStatus.failed:
        return error == null ? '失败' : '失败：$error';
      case FileStatus.canceled:
        return '已取消';
    }
  }

  @override
  String toString() => 'FileTask($id $name $status $transferred/$size)';
}

/// 人读的字节串。保留一位小数，小了就退到 B/KB。
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  double v = bytes.toDouble();
  int i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  if (i == 0) return '$bytes B';
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

final math.Random _rand = math.Random();

/// `f-<毫秒>-<4位随机>`（协议 v3 §2 规则 1）。
String fileTransferId([DateTime? now]) {
  final int ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final int tail = 1000 + _rand.nextInt(9000);
  return 'f-$ms-$tail';
}

/// 只保留 basename 并滤掉非法字符——**这是本地防线，Agent 侧还有一道**
/// （见协议 v3 §2 规则 5：文件传输是写任意文件的高危入口，两边都要挡）。
///
/// 处理：路径分隔符取尾段 → 去掉控制字符与 `<>:"|?*` → 去掉结尾的点/空格
/// → 截到 200 字符 → 空串退回 `unnamed`，`. ` 这类退成 `unnamed`。
String safeFileName(String raw) {
  String s = raw.replaceAll('\\', '/');
  final int slash = s.lastIndexOf('/');
  if (slash >= 0) s = s.substring(slash + 1);
  s = s.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_');
  s = s.replaceAll(RegExp(r'[. ]+$'), '');
  if (s.length > 200) {
    // 保留扩展名，别把 .zip 截掉变成不可打开的怪文件
    final int dot = s.lastIndexOf('.');
    final String ext = (dot > 0 && s.length - dot <= 12) ? s.substring(dot) : '';
    s = s.substring(0, 200 - ext.length) + ext;
  }
  if (s.trim().isEmpty) return 'unnamed';
  return s;
}

/// 冲突改名：`a.zip` → `a (1).zip` → `a (2).zip`（协议 v3 §2 规则 4）。
///
/// [exists] 由调用方提供（服务端查真实磁盘，测试给闭包），
/// 最多试 [maxTries] 次，全冲突就退化成带 id 尾巴的名字。
String uniqueFileName(String name, bool Function(String candidate) exists, {int maxTries = 999}) {
  if (!exists(name)) return name;
  final int dot = name.lastIndexOf('.');
  final bool hasExt = dot > 0 && dot < name.length - 1;
  final String base = hasExt ? name.substring(0, dot) : name;
  final String ext = hasExt ? name.substring(dot) : '';
  for (int i = 1; i <= maxTries; i++) {
    final String candidate = '$base ($i)$ext';
    if (!exists(candidate)) return candidate;
  }
  return '$base (${DateTime.now().millisecondsSinceEpoch})$ext';
}
