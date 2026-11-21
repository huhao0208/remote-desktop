/// 文件传输的协议层 + 收发服务（协议 v3 §1/§2）。
///
/// 三条硬约束决定这里的所有设计，写任何一段代码之前都要先记住它们：
/// 1. 数据走信令 WS 的**文本帧 + base64**，与 `input` 事件共用一条连接，
///    所以发送必须分片、分拍（[FileTransferService.pump]），不能一口气把
///    一个大文件灌进 socket；
/// 2. **发起方决定方向**：`file.offer`/`file.get` 的发出者推块，另一方只按 id 回。
///    两侧帧格式完全相同，只有 id 的生成方能区分，绝不能靠方向字段猜；
/// 3. 文件传输是「写任意文件」的高危入口，落盘路径必须由本机重新拼装并校验。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'file_transfer_model.dart';

/// 协议消息构造器：纯函数、无状态，测试可以直接断言字段。
///
/// 只负责「按冻结的契约拼 map」，不校验业务合法性（大小上限、名字安全）
/// ——那些是服务层的事，混在一起会让两侧的判定规则漂移。
class FileProtocol {
  const FileProtocol._();

  static Map<String, dynamic> offer({
    required String id,
    required String name,
    required int size,
    int offset = 0,
  }) =>
      <String, dynamic>{
        'p': 'file.offer',
        'id': id,
        'name': name,
        'size': size,
        'offset': offset,
      };

  /// [data] 是原始字节，出口处才 base64。单块上限由调用方按 [kFileChunkBytes] 切好。
  static Map<String, dynamic> chunk({
    required String id,
    required int off,
    required List<int> data,
  }) =>
      <String, dynamic>{
        'p': 'file.chunk',
        'id': id,
        'off': off,
        'data': base64Encode(data),
      };

  /// [sha256] 可省略；省略时对端只能靠字节数兜底，可靠性略低。
  static Map<String, dynamic> done(String id, {String? sha256}) => <String, dynamic>{
        'p': 'file.done',
        'id': id,
        if (sha256 != null && sha256.isNotEmpty) 'sha256': sha256,
      };

  static Map<String, dynamic> cancel(String id, {String reason = 'user'}) => <String, dynamic>{
        'p': 'file.cancel',
        'id': id,
        'reason': reason,
      };

  /// 请求下载：`file.get`（不是 `file.offer`）——本端只收块，方向仍是本端发起。
  static Map<String, dynamic> request(String id, String path, {int offset = 0}) =>
      <String, dynamic>{
        'p': 'file.get',
        'id': id,
        'path': path,
        'offset': offset,
      };

  static Map<String, dynamic> list({String dir = ''}) => <String, dynamic>{
        'p': 'file.list',
        'dir': dir,
      };

  // 以下是「本端当接收方」时要回给发起方的帧。契约里列在 Agent → 控制端一栏，
  // 但方向由发起方决定（规则 1），所以谁收到 offer 谁就有资格发这几个。

  static Map<String, dynamic> accept({
    required String id,
    required String name,
    required int size,
    required String path,
    int offset = 0,
    String mode = 'new',
  }) =>
      <String, dynamic>{
        'p': 'file.accept',
        'id': id,
        'name': name,
        'size': size,
        'path': path,
        'offset': offset,
        'mode': mode,
      };

  static Map<String, dynamic> reject(String id, {required String reason}) => <String, dynamic>{
        'p': 'file.reject',
        'id': id,
        'reason': reason,
      };

  static Map<String, dynamic> complete({
    required String id,
    required String path,
    required int bytes,
    String? sha256,
  }) =>
      <String, dynamic>{
        'p': 'file.complete',
        'id': id,
        'path': path,
        'bytes': bytes,
        if (sha256 != null && sha256.isNotEmpty) 'sha256': sha256,
      };

  static Map<String, dynamic> error(String id, {required String reason, String? msg}) =>
      <String, dynamic>{
        'p': 'file.error',
        'id': id,
        'reason': reason,
        if (msg != null && msg.isNotEmpty) 'msg': msg,
      };

  /// `p` 以 `file.` 开头即归文件通道所有，页面据此决定要不要再当 `input` 处理。
  static bool isFileMessage(Map<String, dynamic> msg) {
    final Object? p = msg['p'];
    return p is String && p.startsWith('file.');
  }
}

/// 收发服务：一条 [tasks] 列表 + 一个 [revision] 版本号就是全部对外状态。
///
/// 为什么进度不放在独立流里：UI 每帧本来就要读 [tasks] 渲染，再加一路 Stream
/// 只会让「任务列表」和「进度流」两个真相源对不齐。`revision` 只在
/// 状态/进度真的变化时 +1，页面监听它重建即可。
///
/// 为什么 IO 全部串到一条 [_io] 链上：[handle] 是同步口（调用方是 WS 回调），
/// 但写盘是异步的。链式排队既保证「块按 off 升序写入」不被 async 调度打乱，
/// 也让 `pump()` 有一个确定的「写完」时刻可供测试与页面等待。
class FileTransferService {
  FileTransferService({
    required void Function(Map<String, dynamic> msg) send,
    required Future<Directory> Function() receiveDir,
    int chunkBytes = kFileChunkBytes,
    int maxBytes = kFileMaxBytes,
    int chunksPerPump = 8,
  })  : _sendOut = send,
        _dirOf = receiveDir,
        _chunkSize = chunkBytes,
        _maxSize = maxBytes,
        _burstChunks = chunksPerPump;

  /// 把帧丢给信令 WS（`SignalingClient.sendJson`）。抛异常一律吞掉：
  /// WS 断线时上传任务应该表现为「卡住等重连」，而不是让异常穿透到 UI 定时器。
  final void Function(Map<String, dynamic> msg) _sendOut;

  final Future<Directory> Function() _dirOf;
  final int _chunkSize;
  final int _maxSize;
  final int _burstChunks;

  /// 新的排前面，UI 直接遍历。对象就地改字段，靠 [revision] 触发重绘。
  final List<FileTask> tasks = <FileTask>[];

  /// 任一任务状态/进度变化 → +1。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 上传排队（同一时刻只跑一个上传任务，避免两路 base64 抢同一条 WS）。
  final List<String> _queue = <String>[];

  final Map<String, _UploadState> _uploads = <String, _UploadState>{};

  /// 接收侧（下载 / 被别人推过来）的写盘状态，按 id 索引。
  final Map<String, _RecvState> _recvs = <String, _RecvState>{};

  _UploadState? _sending;
  Future<void> _io = Future<void>.value();
  Future<Directory>? _dirFuture;
  bool _disposed = false;
  bool _pumping = false;

  int get activeCount => tasks.where((FileTask t) => !t.finished).length;

  bool get busy => activeCount > 0;

  // ---------------------------------------------------------------- 上传

  /// 上传本机文件。超过 [kFileMaxBytes] 的不进队列，直接当场判失败
  /// ——「先传 4GB 再被拒」是最糟的用户体验，规则 6 要求入口就挡。
  Future<List<FileTask>> send(List<File> files) async {
    final List<FileTask> created = <FileTask>[];
    for (final File file in files) {
      final String name = safeFileName(file.path);
      int size = 0;
      bool readable = true;
      try {
        size = await file.length();
      } catch (_) {
        readable = false;
      }
      final FileTask task = FileTask(
        id: fileTransferId(),
        name: name,
        size: size,
        direction: FileDirection.upload,
      );
      if (!readable) {
        task.status = FileStatus.failed;
        task.error = '无法读取本机文件';
        tasks.insert(0, task);
        created.add(task);
        _touch();
        continue;
      }
      if (size > _maxSize) {
        task.status = FileStatus.failed;
        task.error = '超过 4 GiB 上限，已拒绝';
        tasks.insert(0, task);
        created.add(task);
        _touch();
        continue;
      }
      tasks.insert(0, task);
      _uploads[task.id] = _UploadState(task.id, file);
      _queue.add(task.id);
      created.add(task);
      _touch();
    }
    _startNextUpload();
    return created;
  }

  /// 下载被控端的绝对路径。总大小发起时未知（`file.accept` 才知道），
  /// 先给 0，收到 accept 后由 [_adoptSize] 换成带真实 size 的新对象。
  FileTask requestDownload(String remotePath) {
    final FileTask task = FileTask(
      id: fileTransferId(),
      name: safeFileName(remotePath),
      size: 0,
      direction: FileDirection.download,
      status: FileStatus.pending,
    );
    tasks.insert(0, task);
    _recvs[task.id] = _RecvState();
    _send(FileProtocol.request(task.id, remotePath));
    _touch();
    return task;
  }

  /// 取消：本端不再发/不再收，并告诉对端别再推。上传取消后立刻让出队列。
  void cancel(String id, {String reason = 'user'}) {
    final FileTask? task = _byId(id);
    if (task == null || task.finished) return;

    final _UploadState? up = _uploads.remove(id);
    if (up != null) {
      _queue.remove(id);
      if (identical(_sending, up)) _sending = null;
      _enqueue(() async {
        try {
          await up.raf?.close();
        } catch (_) {
          // 已经关了/被系统回收，关闭失败不影响「取消」这个结果。
        }
      });
    }
    final _RecvState? recv = _recvs.remove(id);
    if (recv != null) _enqueue(() => _dropReceive(recv));

    task.status = FileStatus.canceled;
    task.error = null;
    _send(FileProtocol.cancel(id, reason: reason));
    _touch();
    _startNextUpload();
  }

  // ---------------------------------------------------------------- 收帧

  /// 收到一条 WS 文本帧。返回 true 表示已被文件通道认领。
  ///
  /// 「认领」比「处理成功」更宽：`file.list.result` 这类本层还没消费的帧也返回
  /// true，否则页面会把它当 `input` 事件再解析一遍，产生莫名其妙的按键。
  bool handle(Map<String, dynamic> msg) {
    if (!FileProtocol.isFileMessage(msg)) return false;
    if (_disposed) return true;
    final Object? idValue = msg['id'];
    if (idValue is! String || idValue.isEmpty) return true;
    switch (msg['p'] as String) {
      case 'file.offer':
        _onOffer(msg, idValue);
        break;
      case 'file.accept':
        _onAccept(msg, idValue);
        break;
      case 'file.reject':
        _onReject(msg, idValue);
        break;
      case 'file.chunk':
        _onChunk(msg, idValue);
        break;
      case 'file.progress':
        _onProgress(msg, idValue);
        break;
      case 'file.done':
        _onDone(msg, idValue);
        break;
      case 'file.complete':
        _onComplete(msg, idValue);
        break;
      case 'file.error':
        _onError(msg, idValue);
        break;
      default:
        break;
    }
    return true;
  }

  /// 对端发起上传（我们是接收方）。落盘路径在这里定，之后不再变。
  void _onOffer(Map<String, dynamic> msg, String id) {
    final FileTask? old = _byId(id);
    if (old != null && old.direction == FileDirection.upload) return; // 自己的 id 回声，忽略
    if (old != null) {
      // 同 id 重发 offer = 对端从 0 重传（规则 2）。旧半截必须清掉，
      // 否则「续写」会把两份数据拼成一个坏文件。
      final _RecvState? prev = _recvs.remove(id);
      if (prev != null) _enqueue(() => _dropReceive(prev));
      old.status = FileStatus.pending;
      old.transferred = 0;
      old.error = null;
    }

    final int size = _int(msg['size']);
    if (size < 0 || size > _maxSize) {
      _send(FileProtocol.reject(id, reason: 'too_large'));
      return;
    }
    final int wantOffset = _int(msg['offset']).clamp(0, size);

    final FileTask task = old ??
        FileTask(
          id: id,
          name: safeFileName(msg['name'] as String? ?? ''),
          size: size,
          direction: FileDirection.download,
        );
    if (old == null) tasks.insert(0, task);
    final _RecvState st = _RecvState();
    _recvs[id] = st;
    _touch();
    _enqueue(() => _acceptOffer(task, st, wantOffset));
  }

  /// 我发出的上传被接受：从 accept 的 offset 开始发（规则 3 续传）。
  void _onAccept(Map<String, dynamic> msg, String id) {
    final _RecvState? recv = _recvs[id];
    if (recv != null) {
      // 我发起的下载被接受：只想知道总大小，其余什么都不用做（块自己会来）。
      final FileTask? task = _byId(id);
      final int size = _int(msg['size']);
      if (task != null) {
        if (size > 0 && size <= _maxSize) _adoptSize(task, size);
        if (task.status == FileStatus.pending) {
          task.status = FileStatus.active;
          _touch();
        }
      }
      return;
    }

    final _UploadState? st = _uploads[id];
    final FileTask? task = _byId(id);
    if (st == null || task == null || task.finished) return;

    final int offset = _int(msg['offset']).clamp(0, task.size);
    final Object? path = msg['path'];
    if (path is String && path.isNotEmpty) task.savePath = path;
    st.gen++; // 新一轮开始，作废上一轮遗留的发送循环
    st.accepted = true;
    st.offset = offset;
    st.lastProgressBytes = offset;
    st.lastProgressAt = _nowMs();
    task.transferred = offset;
    task.status = FileStatus.active;
    _touch();
    _enqueue(() => _openUpload(task, st, offset));
  }

  void _onReject(Map<String, dynamic> msg, String id) {
    final String reason = msg['reason'] as String? ?? '';
    final String text = _reasonText(reason);
    final _UploadState? st = _uploads[id];
    if (st != null) {
      _failUpload(_byId(id), st, text);
      return;
    }
    final FileTask? task = _byId(id);
    if (task == null || task.finished) return;
    _enqueue(() => _failReceive(task, 'io', text));
  }

  void _onChunk(Map<String, dynamic> msg, String id) {
    final _RecvState? st = _recvs[id];
    final FileTask? task = _byId(id);
    if (st == null || task == null || task.finished) return; // 找不到就安静丢弃
    final int off = _int(msg['off']);
    final String encoded = msg['data'] as String? ?? '';
    late final List<int> bytes;
    try {
      bytes = base64Decode(encoded);
    } catch (_) {
      _enqueue(() => _failReceive(task, 'io', '数据块解码失败'));
      return;
    }
    _enqueue(() => _writeChunk(task, st, off, bytes));
  }

  /// 对端汇报的「已收字节数」只用来纠偏上传方向的显示，不参与发送游标。
  ///
  /// 下载方向**绝不能**采信它：块是异步落盘的，`received` 通常跑在本地写盘前面，
  /// 一旦拿它推进 `transferred`，下一块就会写在「以为写过、其实没写」的位置上。
  void _onProgress(Map<String, dynamic> msg, String id) {
    final FileTask? task = _byId(id);
    if (task == null || task.finished) return;
    if (task.direction != FileDirection.upload) return;
    final int received = _int(msg['received']);
    if (received <= task.transferred) return;
    task.transferred = received > task.size && task.size > 0 ? task.size : received;
    _touch();
  }

  void _onDone(Map<String, dynamic> msg, String id) {
    final _RecvState? st = _recvs[id];
    final FileTask? task = _byId(id);
    if (st == null || task == null) return; // 我自己的上传收到 done 回声：忽略
    final Object? sha = msg['sha256'];
    _enqueue(() => _finalizeReceive(task, st, sha is String ? sha : null));
  }

  void _onComplete(Map<String, dynamic> msg, String id) {
    final Object? sha = msg['sha256'];
    final _RecvState? st = _recvs[id];
    final FileTask? task = _byId(id);
    if (st != null && task != null) {
      _enqueue(() => _finalizeReceive(task, st, sha is String ? sha : null));
      return;
    }

    final _UploadState? up = _uploads.remove(id);
    final FileTask? mine = _byId(id);
    if (up == null || mine == null) return;
    _queue.remove(id);
    if (identical(_sending, up)) _sending = null;
    final Object? path = msg['path'];
    if (path is String && path.isNotEmpty) mine.savePath = path;
    mine.status = FileStatus.done;
    mine.transferred = mine.size;
    mine.error = null;
    _enqueue(() async {
      try {
        await up.raf?.close();
      } catch (_) {
        // 收尾关闭失败不影响「已完成」。
      }
    });
    _touch();
    _startNextUpload();
  }

  void _onError(Map<String, dynamic> msg, String id) {
    final String reason = msg['reason'] as String? ?? '';
    final String text = _errorText(reason, msg['msg'] as String?);

    final _UploadState? st = _uploads[id];
    final FileTask? task = _byId(id);
    if (st != null && task != null) {
      // 规则 2：接收方说 off 对不上 → 从 0 重传**一次**。只重试一次是刻意的：
      // 第二次还错说明两侧对文件内容的理解已经分叉，再试只会烧带宽。
      if (reason == 'offset' && !st.retried) {
        st.retried = true;
        _enqueue(() => _restartUpload(task, st));
        return;
      }
      _failUpload(task, st, text);
      return;
    }

    if (task != null && st == null && !task.finished) {
      final _RecvState? recv = _recvs.remove(id);
      if (recv != null) _enqueue(() => _dropReceive(recv));
      task.status = FileStatus.failed;
      task.error = text;
      _touch();
    }
  }

  // ---------------------------------------------------------------- 驱动

  /// 由页面定时器（~16ms）调一次。
  ///
  /// 返回「本次真的发了数据」，页面可据此不必再空转排下一拍。
  Future<bool> pump() async {
    if (_disposed || _pumping) return false;
    _pumping = true;
    try {
      await _flushIo();
      if (_disposed) return false;
      _startNextUpload();
      final _UploadState? st = _sending;
      if (st == null) return false;
      final FileTask? task = _byId(st.id);
      if (task == null || task.finished) return false;
      if (!st.accepted || st.raf == null) return false; // 等 accept
      return await _pumpChunks(task, st);
    } finally {
      _pumping = false;
    }
  }

  Future<bool> _pumpChunks(FileTask task, _UploadState st) async {
    bool sentData = false;
    // 本轮的口令。任何 await 之后都要重新核对：让出的这段时间里游标可能已被重置。
    final int gen = st.gen;
    for (int i = 0; i < _burstChunks; i++) {
      if (_disposed || !identical(_sending, st) || st.raf == null || st.gen != gen) break;
      final int remaining = task.size - st.offset;
      if (remaining <= 0) {
        await _finishUpload(task, st);
        break;
      }
      final int want = remaining < _chunkSize ? remaining : _chunkSize;
      Uint8List buf;
      try {
        buf = await st.raf!.read(want);
      } catch (_) {
        _failUpload(task, st, '读取本机文件失败');
        break;
      }
      if (st.gen != gen) break; // 读盘期间被重传/取消，这一块作废
      if (buf.isEmpty) {
        // 文件在传输过程中被截断：源已不可信，立刻收尾并让对端按字节数报错。
        await _finishUpload(task, st);
        break;
      }
      _send(FileProtocol.chunk(id: task.id, off: st.offset, data: buf));
      st.offset += buf.length;
      st.digestIn?.add(buf);
      task.transferred = st.offset;
      sentData = true;
      _maybeSendProgress(task, st.lastProgressBytes, st.lastProgressAt, () {
        st.lastProgressBytes = task.transferred;
        st.lastProgressAt = _nowMs();
      });
      _touch();
      if (st.offset >= task.size) {
        await _finishUpload(task, st);
        break;
      }
    }
    return sentData;
  }

  // ---------------------------------------------------------------- 上传实现

  Future<void> _openUpload(FileTask task, _UploadState st, int offset) async {
    if (task.finished || !_uploads.containsKey(task.id)) return;
    try {
      final RandomAccessFile raf = await st.file.open();
      if (offset > 0) await raf.setPosition(offset);
      st.raf = raf;
    } catch (_) {
      _failUpload(task, st, '无法读取本机文件');
      return;
    }
    if (offset == 0) {
      // 增量摘要：从 0 起才有效。续传时 offset>0，摘要交给收尾时整读一次。
      final _DigestSink sink = _DigestSink();
      st.digest = sink;
      st.digestIn = sha256.startChunkedConversion(sink);
    }
  }

  Future<void> _finishUpload(FileTask task, _UploadState st) async {
    if (st.doneSent) return;
    st.doneSent = true;
    try {
      await st.raf?.close();
    } catch (_) {
      // 读完了，关闭失败无关结果。
    }
    st.raf = null;

    String? hex;
    try {
      final _DigestSink? sink = st.digest;
      if (sink != null) {
        st.digestIn?.close();
        hex = sink.value?.toString();
      } else {
        // 续传场景没有增量摘要：整读一次算。4GB 双读一次比「把摘要搞错」便宜。
        hex = (await sha256.bind(st.file.openRead()).first).toString();
      }
    } catch (_) {
      hex = null; // 摘要算不出来就不带，至少让对端先落到盘上
    }
    _send(FileProtocol.done(task.id, sha256: hex));
    _touch();
  }

  Future<void> _restartUpload(FileTask task, _UploadState st) async {
    try {
      await st.raf?.close();
    } catch (_) {
      // 重传会重新 open，旧句柄关不掉也不影响。
    }
    st.gen++; // 作废仍在跑的那一轮（见 _UploadState.gen 的注释）
    st.raf = null;
    st.accepted = false;
    st.doneSent = false;
    st.offset = 0;
    st.digest = null;
    st.digestIn = null;
    task.transferred = 0;
    task.status = FileStatus.pending;
    task.error = null;
    _touch();
    _send(FileProtocol.offer(id: task.id, name: task.name, size: task.size));
  }

  void _failUpload(FileTask? task, _UploadState st, String text) {
    _uploads.remove(st.id);
    _queue.remove(st.id);
    if (identical(_sending, st)) _sending = null;
    _enqueue(() async {
      try {
        await st.raf?.close();
      } catch (_) {
        // 失败路径上关闭异常没有信息量。
      }
    });
    if (task != null) {
      task.status = FileStatus.failed;
      task.error = text;
      _send(FileProtocol.error(task.id, reason: 'io', msg: text));
      _touch();
    }
    _startNextUpload();
  }

  void _startNextUpload() {
    if (_disposed || _sending != null) return;
    for (final String id in List<String>.of(_queue)) {
      final _UploadState? st = _uploads[id];
      final FileTask? task = _byId(id);
      if (st == null || task == null || task.finished) {
        _queue.remove(id);
        continue;
      }
      _sending = st;
      _queue.remove(id);
      _send(FileProtocol.offer(id: id, name: task.name, size: task.size));
      _touch();
      return;
    }
  }

  // ---------------------------------------------------------------- 接收实现

  Future<void> _acceptOffer(FileTask task, _RecvState st, int wantOffset) async {
    if (task.finished || !identical(_recvs[task.id], st)) return;
    try {
      await _prepareTarget(task, st, resumeOffset: wantOffset);
    } catch (_) {
      await _failReceive(task, 'io', '接收目录不可写');
      return;
    }
    int offset = 0;
    final String partPath = st.partPath!;
    if (wantOffset > 0) {
      try {
        final File part = File(partPath);
        if (await part.exists() && await part.length() == wantOffset) offset = wantOffset;
      } catch (_) {
        offset = 0;
      }
    }
    try {
      // 只有真正「长度对得上」才 append；否则截断重来，半截数据绝不能续上。
      st.raf = await File(partPath).open(mode: offset > 0 ? FileMode.append : FileMode.write);
    } catch (_) {
      await _failReceive(task, 'io', '无法创建临时文件');
      return;
    }
    task.transferred = offset;
    task.status = FileStatus.active;
    st.lastProgressBytes = offset;
    st.lastProgressAt = _nowMs();
    _touch();
    _send(FileProtocol.accept(
      id: task.id,
      name: task.name,
      size: task.size,
      path: st.finalPath!,
      offset: offset,
      mode: offset > 0 ? 'append' : 'new',
    ));
  }

  Future<void> _ensureReceiveTarget(FileTask task, _RecvState st) async {
    if (st.raf != null) return;
    if (st.partPath == null) await _prepareTarget(task, st);
    st.raf = await File(st.partPath!).open(mode: FileMode.write);
    st.lastProgressBytes = task.transferred;
    st.lastProgressAt = _nowMs();
  }

  Future<void> _writeChunk(FileTask task, _RecvState st, int off, List<int> data) async {
    // 队列里可能还压着上一轮（已失败/已重传）的块，认轮次不认 id：
    // 只处理属于当前这一轮 _RecvState 的块，否则重传会被旧块判成错位。
    if (task.finished || !identical(_recvs[task.id], st)) return;
    if (off != task.transferred) {
      // 规则 2：不重排、不拼接。错位即失败，由发起方从 0 重传。
      await _failReceive(task, 'offset', '数据块顺序错乱（期望 ${task.transferred}，收到 $off）');
      return;
    }
    try {
      await _ensureReceiveTarget(task, st);
      await st.raf!.writeFrom(data);
    } catch (_) {
      await _failReceive(task, 'io', '写入本机文件失败');
      return;
    }
    task.transferred += data.length;
    _maybeSendProgress(task, st.lastProgressBytes, st.lastProgressAt, () {
      st.lastProgressBytes = task.transferred;
      st.lastProgressAt = _nowMs();
    });
    _touch();
  }

  Future<void> _finalizeReceive(FileTask task, _RecvState st, String? sha) async {
    if (task.finished || !identical(_recvs[task.id], st)) return;
    try {
      await _ensureReceiveTarget(task, st);
      await st.raf!.flush();
      await st.raf!.close();
    } catch (_) {
      await _failReceive(task, 'io', '写入本机文件失败');
      return;
    }
    st.raf = null;

    if (task.size > 0 && task.transferred != task.size) {
      await _failReceive(
        task,
        'io',
        '字节数不符（期望 ${task.size}，收到 ${task.transferred}）',
      );
      return;
    }

    final String partPath = st.partPath!;
    final String finalPath = st.finalPath!;
    if (sha != null && sha.isNotEmpty) {
      String? actual;
      try {
        actual = (await sha256.bind(File(partPath).openRead()).first).toString();
      } catch (_) {
        actual = null;
      }
      if (actual != null && actual != sha) {
        // 坏文件必须删：留着会让用户以为「收到了但打不开」，比明说失败更糟。
        await _failReceive(task, 'sha256', '校验失败（文件已损坏）');
        return;
      }
    }

    try {
      // `.part` → 最终名的唯一切换点。半截文件永远停在 `.part` 上，
      // 接收目录里不会出现「看起来完整、其实没写完」的同名文件。
      await File(partPath).rename(finalPath);
    } catch (_) {
      await _failReceive(task, 'io', '保存文件失败');
      return;
    }

    _recvs.remove(task.id);
    task.status = FileStatus.done;
    task.savePath = finalPath;
    task.error = null;
    _touch();
    _send(FileProtocol.complete(
      id: task.id,
      path: finalPath,
      bytes: task.transferred,
      sha256: sha,
    ));
  }

  Future<void> _failReceive(FileTask task, String reason, String text) async {
    final _RecvState? st = _recvs.remove(task.id);
    if (st != null) await _dropReceive(st);
    task.status = FileStatus.failed;
    task.error = text;
    _send(FileProtocol.error(task.id, reason: reason, msg: text));
    _touch();
  }

  Future<void> _dropReceive(_RecvState st) async {
    try {
      await st.raf?.close();
    } catch (_) {
      // 已关闭 / 系统已回收。
    }
    st.raf = null;
    final String? part = st.partPath;
    if (part == null) return;
    try {
      final File file = File(part);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删不掉就留在 `.part` 上：不会污染最终文件名，也不影响下次重传时的截断。
    }
  }

  /// 决定落盘名字与 `.part` 路径。
  ///
  /// 安全校验放在这里而不是散在调用点：名字来自网络，路径拼完必须再验一次
  /// 「确实落在接收目录内」。用绝对路径 + 分隔符做前缀比较，是因为
  /// `startsWith('/tmp/x')` 会把 `/tmp/x-evil` 也放进来，必须带尾部 `/`。
  Future<void> _prepareTarget(FileTask task, _RecvState st, {int resumeOffset = 0}) async {
    final Directory dir = await _dir();
    if (!await dir.exists()) await dir.create(recursive: true);
    final String root = dir.absolute.path;

    if (resumeOffset > 0) {
      final String plain = _join(root, task.name);
      final File part = File('$plain.part');
      bool same = false;
      try {
        same = await part.exists() && await part.length() == resumeOffset;
      } catch (_) {
        same = false;
      }
      if (same && _inside(plain, root)) {
        st.finalPath = plain;
        st.partPath = '$plain.part';
        return;
      }
    }

    bool taken(String name) {
      final String path = _join(root, name);
      return File(path).existsSync() || File('$path.part').existsSync();
    }

    final String name = uniqueFileName(task.name, taken);
    final String finalPath = _join(root, name);
    if (!_inside(finalPath, root)) {
      throw FileSystemException('落盘路径越界', finalPath);
    }
    st.finalPath = finalPath;
    st.partPath = '$finalPath.part';
  }

  // ---------------------------------------------------------------- 工具

  /// 进度节流（规则 7）：对端不需要每个块都知道，1MiB 或 500ms 一次就够。
  /// 调用方传「上次发出的时间/字节」进来，由闭包决定是否推进游标，
  /// 这样服务里只有一处节流逻辑，上传与下载共用同一套阈值。
  void _maybeSendProgress(
    FileTask task,
    int lastBytes,
    int lastAt,
    void Function() markSent,
  ) {
    final bool enoughBytes = task.transferred - lastBytes >= kFileProgressBytes;
    final bool enoughTime = _nowMs() - lastAt >= kFileProgressInterval.inMilliseconds;
    if (!enoughBytes && !enoughTime) return;
    markSent();
    _send(<String, dynamic>{
      'p': 'file.progress',
      'id': task.id,
      'received': task.transferred,
    });
  }

  /// `file.accept` 带来了真实大小，但 [FileTask.size] 是 final（模型只读）。
  /// 这里换一个同 id 的新对象并 +revision，页面监听 [revision] 重建，
  /// 进度条才不会从「0% → 100%」突然跳一下。
  void _adoptSize(FileTask task, int size) {
    if (task.size == size) return;
    final int index = tasks.indexOf(task);
    if (index < 0) return;
    final FileTask fresh = FileTask(
      id: task.id,
      name: task.name,
      size: size,
      direction: task.direction,
      savePath: task.savePath,
      status: task.status,
    )
      ..transferred = task.transferred
      ..error = task.error;
    tasks[index] = fresh;
    _touch();
  }

  FileTask? _byId(String id) {
    for (final FileTask task in tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  Future<Directory> _dir() => _dirFuture ??= _dirOf();

  Future<void> _flushIo() async {
    try {
      await _io;
    } catch (_) {
      // 链上的操作自己已经把失败写进任务状态，这里只负责等它跑完。
    }
  }

  void _enqueue(Future<void> Function() op) {
    _io = _io.then((_) => op()).catchError((Object _) {
      // 单条操作异常不能断链，否则后续块、收尾全部静默丢失。
    });
  }

  void _send(Map<String, dynamic> msg) {
    if (_disposed) return;
    try {
      _sendOut(msg);
    } catch (_) {
      // WS 已断：帧丢弃，任务停在「发送中」等重连后的下一次 offer。
    }
  }

  void _touch() {
    if (_disposed) return;
    revision.value = revision.value + 1;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final _UploadState st in _uploads.values) {
      try {
        await st.raf?.close();
      } catch (_) {
        // 退出路径，尽力而为。
      }
    }
    for (final _RecvState st in _recvs.values) {
      try {
        await st.raf?.close();
      } catch (_) {
        // 同上。
      }
    }
    _uploads.clear();
    _recvs.clear();
    _queue.clear();
    _sending = null;
    revision.dispose();
  }
}

class _UploadState {
  _UploadState(this.id, this.file);

  final String id;
  final File file;
  RandomAccessFile? raf;

  /// 下一块的起始偏移，也是「已发出字节数」。
  int offset = 0;
  int lastProgressBytes = 0;
  int lastProgressAt = 0;
  bool accepted = false;
  bool retried = false;
  bool doneSent = false;

  /// 发送轮次。每次「重新开始发」（accept 落地 / 从 0 重传）都 +1。
  ///
  /// 为什么必须有：`_pumpChunks` 里 `await raf.read()` 会让出事件循环，
  /// 这期间 `_io` 队列可能已经跑完 accept/restart 并把 `offset` 重置成 0。
  /// 没有轮次号的话，那次 await 回来后循环会拿**新**游标再发一遍 0 号块，
  /// 接收端第二次判错位，重传永远成功不了（实测踩到过）。
  int gen = 0;
  _DigestSink? digest;
  ByteConversionSink? digestIn;
}

class _RecvState {
  RandomAccessFile? raf;
  String? partPath;
  String? finalPath;
  int lastProgressBytes = 0;
  int lastProgressAt = 0;
}

/// `startChunkedConversion` 要一个 `Sink<Digest>`，而 package:convert 的
/// `AccumulatorSink` 不在依赖里（也不想为一个字段多加依赖）。自己实现三行即可：
/// 摘要只在 `close()` 时吐一次，存下最后一个值就够了。
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

/// 拼接路径时不引入 `package:path`（它是一个未声明为直接依赖的传递依赖）。
String _join(String root, String name) {
  if (root.endsWith(Platform.pathSeparator)) return '$root$name';
  return '$root${Platform.pathSeparator}$name';
}

/// `path` 必须严格位于 `root` 之下（带分隔符比较，挡住 `/tmp/x-evil` 这类前缀混淆）。
bool _inside(String path, String root) {
  final String prefix = root.endsWith(Platform.pathSeparator) ? root : '$root${Platform.pathSeparator}';
  return path.startsWith(prefix) && path.length > prefix.length;
}

String _reasonText(String reason) {
  switch (reason) {
    case 'denied':
      return '被控端拒绝接收';
    case 'no_space':
      return '被控端磁盘空间不足';
    case 'too_large':
      return '文件超过 4 GiB 上限';
    case 'bad_name':
      return '文件名不合法';
    case 'unsupported':
      return '被控端不支持文件传输';
    default:
      return reason.isEmpty ? '被控端拒绝接收' : '被控端拒绝接收（$reason）';
  }
}

String _errorText(String reason, String? msg) {
  if (msg != null && msg.isNotEmpty) return msg;
  switch (reason) {
    case 'offset':
      return '数据块顺序错乱';
    case 'io':
      return '对端读写失败';
    case 'sha256':
      return '校验失败（文件已损坏）';
    case 'not_found':
      return '被控端找不到该文件';
    default:
      return reason.isEmpty ? '传输失败' : '传输失败（$reason）';
  }
}
