import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/file_transfer.dart';
import 'package:uu_remote/core/file_transfer_model.dart';

/// 造一个临时接收目录，测试结束由调用方清理。
Future<Directory> _tempDir() => Directory.systemTemp.createTemp('ft_test_');

/// 造一个内容确定的文件（i % 251，避免全 0 让 sha 校验形同虚设）。
Future<File> _makeFile(Directory dir, String name, int bytes) async {
  final File file = File('${dir.path}/$name');
  await file.writeAsBytes(List<int>.generate(bytes, (int i) => i % 251));
  return file;
}

/// A、B 两个服务的直连回环：A 发出的帧立刻进 B，B 的回包立刻进 A。
///
/// 这就是「控制端 ↔ 被控端」的最小心智模型：两端跑同一份协议实现，
/// 只要回环能传完，字段拼写、方向判定、off 游标就都是自洽的。
class _Pair {
  _Pair(Directory aDir, Directory bDir, {int chunkBytes = 4096}) {
    a = FileTransferService(
      send: (Map<String, dynamic> msg) {
        aSent.add(msg);
        b.handle(msg);
      },
      receiveDir: () async => aDir,
      chunkBytes: chunkBytes,
    );
    b = FileTransferService(
      send: (Map<String, dynamic> msg) {
        bSent.add(msg);
        a.handle(msg);
      },
      receiveDir: () async => bDir,
      chunkBytes: chunkBytes,
    );
  }

  late final FileTransferService a;
  late final FileTransferService b;

  /// A 的出口帧（客户端→被控端方向），用来数块、数 progress。
  final List<Map<String, dynamic>> aSent = <Map<String, dynamic>>[];

  /// B 的出口帧（被控端→客户端方向）。
  final List<Map<String, dynamic>> bSent = <Map<String, dynamic>>[];

  int count(String pattern) => aSent.where((Map<String, dynamic> m) => m['p'] == pattern).length;
}

/// 轮询驱动到两端都没有未完成任务为止。
///
/// 收尾那一步（rename + complete 回包）是在异步链里跑的，`busy` 变 false 时
/// 可能还有一条写盘操作没落完，所以再空跑一轮确认稳定。
Future<void> _drive(List<FileTransferService> services) async {
  for (int i = 0; i < 2000; i++) {
    for (final FileTransferService service in services) {
      await service.pump();
    }
    if (services.every((FileTransferService s) => !s.busy)) {
      for (final FileTransferService service in services) {
        await service.pump();
      }
      if (services.every((FileTransferService s) => !s.busy)) return;
    }
  }
  fail('传输在 2000 轮内没有结束');
}

List<String> _partFiles(Directory dir) => dir
    .listSync()
    .map((FileSystemEntity e) => e.path)
    .where((String path) => path.endsWith('.part'))
    .toList();

void main() {
  group('模型助手', () {
    test('formatBytes 在单位边界上正确切换', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(10 * 1024 * 1024), '10.0 MB');
      expect(formatBytes(kFileMaxBytes), '4.0 GB');
    });

    test('safeFileName 只留 basename，并滤掉危险字符', () {
      expect(safeFileName('../../etc/passwd'), 'passwd');
      expect(safeFileName('/Users/x/a.zip'), 'a.zip');
      expect(safeFileName(r'C:\Users\x\a.zip'), 'a.zip');
      expect(safeFileName('a\u0000b\u001fc.txt'), 'a_b_c.txt');
      // `<>:"|?*` 共 7 个字符 → 7 个下划线；点号是合法字符，原样保留
      expect(safeFileName('report.<>:"|?*.pdf'), 'report._______.pdf');
      expect(safeFileName('trailing.'), 'trailing');
      expect(safeFileName('   '), 'unnamed');
      expect(safeFileName(''), 'unnamed');
      expect(safeFileName('..'), 'unnamed');
    });

    test('safeFileName 超长时保留扩展名', () {
      final String long = '${'a' * 300}.zip';
      final String safe = safeFileName(long);
      expect(safe.length, 200);
      expect(safe.endsWith('.zip'), isTrue);
    });

    test('uniqueFileName 逐个加序号，冲突到底就退化成时间戳尾巴', () {
      final Set<String> taken = <String>{'a.zip'};
      expect(uniqueFileName('a.zip', taken.contains), 'a (1).zip');
      taken.add('a (1).zip');
      expect(uniqueFileName('a.zip', taken.contains), 'a (2).zip');
      expect(uniqueFileName('noext', (_) => false), 'noext');
      expect(uniqueFileName('a.zip', (_) => true, maxTries: 2), isNot('a (1).zip'));
    });

    test('fileTransferId 形如 f-毫秒-4位随机', () {
      final String id = fileTransferId();
      expect(RegExp(r'^f-\d{13}-\d{4}$').hasMatch(id), isTrue);
      expect(fileTransferId(DateTime.fromMillisecondsSinceEpoch(1700000000000)),
          startsWith('f-1700000000000-'));
    });
  });

  group('协议构造', () {
    test('chunk 的 base64 能解回原字节', () {
      final List<int> data = List<int>.generate(1000, (int i) => (i * 7) % 256);
      final Map<String, dynamic> msg = FileProtocol.chunk(id: 'f-1-0001', off: 2048, data: data);
      expect(msg['p'], 'file.chunk');
      expect(msg['id'], 'f-1-0001');
      expect(msg['off'], 2048);
      expect(base64Decode(msg['data'] as String), data);
    });

    test('offer/request/done/cancel/list 字段与契约一致', () {
      expect(
        FileProtocol.offer(id: 'f-1-0001', name: 'a.zip', size: 10),
        <String, dynamic>{'p': 'file.offer', 'id': 'f-1-0001', 'name': 'a.zip', 'size': 10, 'offset': 0},
      );
      expect(FileProtocol.request('f-1-0001', '/x/a.zip')['p'], 'file.get');
      expect(FileProtocol.request('f-1-0001', '/x/a.zip')['path'], '/x/a.zip');
      expect(FileProtocol.done('f-1-0001'), <String, dynamic>{'p': 'file.done', 'id': 'f-1-0001'});
      expect(FileProtocol.done('f-1-0001', sha256: 'ab')['sha256'], 'ab');
      expect(FileProtocol.cancel('f-1-0001')['reason'], 'user');
      expect(FileProtocol.list(), <String, dynamic>{'p': 'file.list', 'dir': ''});
    });

    test('isFileMessage 只认 file. 前缀', () {
      expect(FileProtocol.isFileMessage(<String, dynamic>{'p': 'file.chunk'}), isTrue);
      expect(FileProtocol.isFileMessage(<String, dynamic>{'p': 'file.list.result'}), isTrue);
      expect(FileProtocol.isFileMessage(<String, dynamic>{'p': 'input'}), isFalse);
      expect(FileProtocol.isFileMessage(<String, dynamic>{'p': 'filed'}), isFalse);
      expect(FileProtocol.isFileMessage(<String, dynamic>{}), isFalse);
    });
  });

  group('双服务回环', () {
    late Directory aDir;
    late Directory bDir;

    setUp(() async {
      aDir = await _tempDir();
      bDir = await _tempDir();
    });

    tearDown(() async {
      for (final Directory dir in <Directory>[aDir, bDir]) {
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    });

    test('上传 100KB：两端 done，字节一致，progress 为 1，.part 已清理', () async {
      final File src = await _makeFile(aDir, 'big.bin', 100 * 1024);
      final List<int> expected = await src.readAsBytes();
      final _Pair pair = _Pair(aDir, bDir);

      await pair.a.send(<File>[src]);
      await _drive(<FileTransferService>[pair.a, pair.b]);

      final FileTask up = pair.a.tasks.single;
      expect(up.status, FileStatus.done);
      expect(up.progress, 1.0);
      expect(up.transferred, expected.length);
      expect(up.error, isNull);

      final FileTask down = pair.b.tasks.single;
      expect(down.direction, FileDirection.download);
      expect(down.status, FileStatus.done);
      expect(down.progress, 1.0);

      final File saved = File('${bDir.path}/big.bin');
      expect(down.savePath, saved.path);
      expect(await saved.exists(), isTrue);
      expect(await saved.readAsBytes(), expected);
      expect(_partFiles(bDir), isEmpty);
    });

    test('同名二次传输落成 a (1).bin，第一份内容不变', () async {
      final File src = await _makeFile(aDir, 'a.bin', 9000);
      final List<int> expected = await src.readAsBytes();
      final _Pair pair = _Pair(aDir, bDir);

      await pair.a.send(<File>[src]);
      await _drive(<FileTransferService>[pair.a, pair.b]);
      await pair.a.send(<File>[src]);
      await _drive(<FileTransferService>[pair.a, pair.b]);

      expect(pair.a.tasks.every((FileTask t) => t.status == FileStatus.done), isTrue);
      final File first = File('${bDir.path}/a.bin');
      final File second = File('${bDir.path}/a (1).bin');
      expect(await first.readAsBytes(), expected);
      expect(await second.readAsBytes(), expected);
      expect(pair.b.tasks.first.savePath, second.path);
    });

    test('第一个任务失败后队列继续跑下一个', () async {
      final File good = await _makeFile(aDir, 'good.bin', 5000);
      final File missing = File('${aDir.path}/missing.bin');
      final _Pair pair = _Pair(aDir, bDir);

      final List<FileTask> created = await pair.a.send(<File>[missing, good]);
      await _drive(<FileTransferService>[pair.a, pair.b]);

      expect(created[0].status, FileStatus.failed);
      expect(created[1].status, FileStatus.done);
      expect(await File('${bDir.path}/good.bin').exists(), isTrue);
    });

    test('块错位一次 → 发起方从 0 重传一次后成功', () async {
      final File src = await _makeFile(aDir, 'retry.bin', 40 * 1024);
      final List<int> expected = await src.readAsBytes();
      final List<Map<String, dynamic>> aSent = <Map<String, dynamic>>[];
      final List<Map<String, dynamic>> bSent = <Map<String, dynamic>>[];
      late FileTransferService a;
      late FileTransferService b;
      bool corrupted = false;

      a = FileTransferService(
        send: (Map<String, dynamic> msg) {
          aSent.add(msg);
          Map<String, dynamic> out = msg;
          // 只弄坏第一块：B 判错位 → file.error offset → A 重传一次，
          // 这次数据正常，用来验证「只重试一次」的正向路径。
          if (msg['p'] == 'file.chunk' && !corrupted) {
            corrupted = true;
            out = Map<String, dynamic>.of(msg)..['off'] = 3;
          }
          b.handle(out);
        },
        receiveDir: () async => aDir,
        chunkBytes: 4096,
      );
      b = FileTransferService(
        send: (Map<String, dynamic> msg) {
          bSent.add(msg);
          a.handle(msg);
        },
        receiveDir: () async => bDir,
        chunkBytes: 4096,
      );

      await a.send(<File>[src]);
      await _drive(<FileTransferService>[a, b]);

      expect(corrupted, isTrue);
      expect(a.tasks.single.status, FileStatus.done);
      expect(aSent.where((Map<String, dynamic> m) => m['p'] == 'file.offer').length, 2);
      expect(await File('${bDir.path}/retry.bin').readAsBytes(), expected);
      expect(_partFiles(bDir), isEmpty);
    });
  });

  group('接收侧（被推文件 / 下载）', () {
    late Directory dir;
    late List<Map<String, dynamic>> sent;
    late FileTransferService service;

    setUp(() async {
      dir = await _tempDir();
      sent = <Map<String, dynamic>>[];
      service = FileTransferService(
        send: sent.add,
        receiveDir: () async => dir,
        chunkBytes: 4096,
      );
    });

    tearDown(() async {
      await service.dispose();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('offer 名带 ../ 也只落在接收目录内', () async {
      const String id = 'f-1700000000000-0001';
      final List<int> data = <int>[1, 2, 3, 4];
      service.handle(FileProtocol.offer(id: id, name: '../../etc/passwd', size: data.length));
      service.handle(FileProtocol.chunk(id: id, off: 0, data: data));
      service.handle(FileProtocol.done(id, sha256: sha256.convert(data).toString()));
      await service.pump();

      final FileTask task = service.tasks.single;
      expect(task.status, FileStatus.done);
      expect(task.savePath, '${dir.path}/passwd');
      expect(await File('${dir.path}/passwd').readAsBytes(), data);
      expect(dir.listSync().length, 1);
    });

    test('块 off 错位 → 任务 failed、回 file.error：offset、临时文件被清掉', () async {
      const String id = 'f-1700000000000-0002';
      service.handle(FileProtocol.offer(id: id, name: 'x.bin', size: 8));
      service.handle(FileProtocol.chunk(id: id, off: 4, data: <int>[1, 2, 3, 4]));
      await service.pump();

      final FileTask task = service.tasks.single;
      expect(task.status, FileStatus.failed);
      expect(task.error, contains('顺序'));
      expect(task.savePath, isNull);
      expect(_partFiles(dir), isEmpty);
      expect(dir.listSync(), isEmpty);
      final Map<String, dynamic> error = sent.firstWhere(
        (Map<String, dynamic> m) => m['p'] == 'file.error',
      );
      expect(error['reason'], 'offset');
    });

    test('size 超过上限的 offer 直接 reject，不建任务', () async {
      const String id = 'f-1700000000000-0003';
      service.handle(FileProtocol.offer(id: id, name: 'huge.iso', size: kFileMaxBytes + 1));
      await service.pump();

      expect(service.tasks, isEmpty);
      final Map<String, dynamic> reject = sent.firstWhere(
        (Map<String, dynamic> m) => m['p'] == 'file.reject',
      );
      expect(reject['reason'], 'too_large');
    });

    test('requestDownload 发 file.get，收完块后按 sha256 校验落盘', () async {
      final List<int> data = List<int>.generate(9000, (int i) => (i * 13) % 256);
      final FileTask created = service.requestDownload('/remote/dir/a.bin');
      expect(sent.single['p'], 'file.get');
      expect(sent.single['path'], '/remote/dir/a.bin');

      service.handle(FileProtocol.accept(
        id: created.id,
        name: 'a.bin',
        size: data.length,
        path: '/remote/dir/a.bin',
      ));
      for (int off = 0; off < data.length; off += 4096) {
        final int end = off + 4096 > data.length ? data.length : off + 4096;
        service.handle(FileProtocol.chunk(id: created.id, off: off, data: data.sublist(off, end)));
      }
      service.handle(FileProtocol.complete(
        id: created.id,
        path: '/remote/dir/a.bin',
        bytes: data.length,
        sha256: sha256.convert(data).toString(),
      ));
      await service.pump();

      final FileTask task = service.tasks.single;
      expect(task.status, FileStatus.done);
      // 总大小只在 accept 里出现，任务对象会被换成带真实 size 的新实例。
      expect(task.size, data.length);
      expect(task.progress, 1.0);
      expect(await File('${dir.path}/a.bin').readAsBytes(), data);
      expect(_partFiles(dir), isEmpty);
    });

    test('下载的 sha256 不符 → failed 且坏文件被删除', () async {
      final List<int> data = List<int>.generate(500, (int i) => i % 256);
      final FileTask created = service.requestDownload('/remote/b.bin');
      service.handle(FileProtocol.chunk(id: created.id, off: 0, data: data));
      service.handle(FileProtocol.complete(
        id: created.id,
        path: '/remote/b.bin',
        bytes: data.length,
        sha256: sha256.convert(<int>[9, 9, 9]).toString(),
      ));
      await service.pump();

      final FileTask task = service.tasks.single;
      expect(task.status, FileStatus.failed);
      expect(task.error, contains('校验'));
      expect(dir.listSync(), isEmpty);
    });

    test('未知 id 的块被安静忽略，不报错不建任务', () async {
      service.handle(FileProtocol.chunk(id: 'f-1700000000000-9999', off: 0, data: <int>[1]));
      service.handle(FileProtocol.done('f-1700000000000-9999'));
      await service.pump();

      expect(service.tasks, isEmpty);
      expect(sent, isEmpty);
    });
  });

  group('发送侧边界', () {
    test('超过上限的文件当场失败，且一帧都不发', () async {
      final Directory dir = await _tempDir();
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final File big = await _makeFile(dir, 'big.bin', 4096);
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final FileTransferService service = FileTransferService(
        send: sent.add,
        receiveDir: () async => dir,
        maxBytes: 1024,
      );
      addTearDown(service.dispose);

      final List<FileTask> created = await service.send(<File>[big]);
      await service.pump();

      expect(created.single.status, FileStatus.failed);
      expect(created.single.error, contains('4 GiB'));
      expect(sent, isEmpty);
    });

    test('取消后 pump 不再发块', () async {
      final Directory aDir = await _tempDir();
      final Directory bDir = await _tempDir();
      addTearDown(() async {
        for (final Directory d in <Directory>[aDir, bDir]) {
          if (await d.exists()) await d.delete(recursive: true);
        }
      });
      final File src = await _makeFile(aDir, 'cancel.bin', 400 * 1024);
      final _Pair pair = _Pair(aDir, bDir);

      final List<FileTask> created = await pair.a.send(<File>[src]);
      // 第一拍 A 只发 file.offer；B 收到后把 accept 排进自己的 IO 队列，
      // 必须驱动 B 才会回包，再驱动 A 才开始推块——这就是真实往返的三拍。
      for (int i = 0; i < 6 && pair.count('file.chunk') == 0; i++) {
        await pair.a.pump();
        await pair.b.pump();
      }
      expect(pair.count('file.chunk'), greaterThan(0), reason: '三拍内应已开始推块');
      expect(created.single.status, FileStatus.active);
      expect(pair.count('file.chunk'), lessThan(400 * 1024 ~/ 4096), reason: '远没发完');

      pair.a.cancel(created.single.id);
      expect(created.single.status, FileStatus.canceled);
      final int framesAfterCancel = pair.aSent.length;

      for (int i = 0; i < 5; i++) {
        await pair.a.pump();
        await pair.b.pump();
      }
      expect(pair.aSent.length, framesAfterCancel, reason: '取消后不应再有任何退出帧');
      expect(pair.count('file.chunk'), lessThan(400 * 1024 ~/ 4096));
    });

    test('100KB 文件的 file.progress 不超过 2 条（节流生效）', () async {
      final Directory aDir = await _tempDir();
      final Directory bDir = await _tempDir();
      addTearDown(() async {
        for (final Directory d in <Directory>[aDir, bDir]) {
          if (await d.exists()) await d.delete(recursive: true);
        }
      });
      final File src = await _makeFile(aDir, 'small.bin', 100 * 1024);
      final _Pair pair = _Pair(aDir, bDir);

      await pair.a.send(<File>[src]);
      await _drive(<FileTransferService>[pair.a, pair.b]);

      expect(pair.a.tasks.single.status, FileStatus.done);
      expect(pair.count('file.progress'), lessThanOrEqualTo(2));
    });
  });
}
