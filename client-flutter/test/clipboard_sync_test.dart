import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/clipboard_sync.dart';

/// 假剪贴板：记录写入、按脚本返回读取结果，并可模拟平台异常。
///
/// 走注入而不是真 [Clipboard]，单测就不依赖 platform channel，
/// 也不会把开发者本机剪贴板洗掉。
class _FakeClipboard {
  _FakeClipboard({this.readValue});

  /// 下一次读取返回什么（null 表示剪贴板里没有文本）。
  String? readValue;

  /// 读取是否抛异常（模拟无窗口/沙盒下的 PlatformException）。
  bool readThrows = false;

  /// 写入是否抛异常。
  bool writeThrows = false;

  /// 每次成功写入的内容，用来断言「写没写、写了几次、写了什么」。
  final List<String> writes = <String>[];

  /// 读取调用次数（用来验证开关关闭时压根不读平台）。
  int reads = 0;

  Future<String?> read() async {
    reads++;
    if (readThrows) throw StateError('平台读取失败');
    return readValue;
  }

  Future<void> write(String text) async {
    if (writeThrows) throw StateError('平台写入失败');
    writes.add(text);
  }

  ClipboardSync sync({int maxChars = 200000, bool enabled = true}) => ClipboardSync(
        readClipboard: read,
        writeClipboard: write,
        maxChars: maxChars,
        enabled: enabled,
      );
}

void main() {
  group('下行写入（applyRemote）', () {
    test('正常写入：返回 applied，假写实现收到原文，lastText 随之更新', () async {
      final _FakeClipboard fake = _FakeClipboard();
      final ClipboardSync sync = fake.sync();

      final ClipboardApplyResult result = await sync.applyRemote('hello 被控端');

      expect(result, ClipboardApplyResult.applied);
      expect(fake.writes, <String>['hello 被控端']);
      expect(sync.lastText, 'hello 被控端');
      expect(sync.lastSkip, isNull);
    });

    test('与上次已知值相同：返回 skippedSame，且不重复写剪贴板', () async {
      final _FakeClipboard fake = _FakeClipboard();
      final ClipboardSync sync = fake.sync();

      await sync.applyRemote('同一条');
      final ClipboardApplyResult again = await sync.applyRemote('同一条');

      expect(again, ClipboardApplyResult.skippedSame);
      expect(fake.writes.length, 1);
      expect(sync.lastSkip, ClipboardApplyResult.skippedSame);
      // 跳过后已知值保持原样，不被污染
      expect(sync.lastText, '同一条');
    });

    test('上行回声抑制：markUploaded 后紧随的等值下行必须被跳过', () async {
      final _FakeClipboard fake = _FakeClipboard();
      final ClipboardSync sync = fake.sync();

      // 场景：本机复制 → 上行 → 被控端改自己剪贴板 → 推同值回来
      sync.markUploaded('本机刚复制的内容');
      final ClipboardApplyResult result = await sync.applyRemote('本机刚复制的内容');

      expect(result, ClipboardApplyResult.skippedSame);
      expect(fake.writes, isEmpty, reason: '回声不能覆盖本机剪贴板');
    });

    test('超长（maxChars+1）跳过且不截断，剪贴板一个字节都不写', () async {
      final _FakeClipboard fake = _FakeClipboard();
      final ClipboardSync sync = fake.sync(maxChars: 5);

      final ClipboardApplyResult result = await sync.applyRemote('123456');

      expect(result, ClipboardApplyResult.skippedTooLong);
      expect(fake.writes, isEmpty);
      expect(sync.lastText, isNull);
      expect(sync.lastSkip, ClipboardApplyResult.skippedTooLong);
    });

    test('边界：长度正好等于 maxChars 仍算通过', () async {
      final _FakeClipboard fake = _FakeClipboard();
      final ClipboardSync sync = fake.sync(maxChars: 5);

      final ClipboardApplyResult result = await sync.applyRemote('12345');

      expect(result, ClipboardApplyResult.applied);
      expect(fake.writes, <String>['12345']);
    });

    test('空串跳过：返回 skippedEmpty，不写剪贴板', () async {
      final _FakeClipboard fake = _FakeClipboard();
      final ClipboardSync sync = fake.sync();

      final ClipboardApplyResult result = await sync.applyRemote('');

      expect(result, ClipboardApplyResult.skippedEmpty);
      expect(fake.writes, isEmpty);
      expect(sync.lastSkip, ClipboardApplyResult.skippedEmpty);
    });

    test('全空白跳过，且不把空白登记为已知值', () async {
      final _FakeClipboard fake = _FakeClipboard();
      final ClipboardSync sync = fake.sync();

      final ClipboardApplyResult result = await sync.applyRemote(' \n\t  ');

      expect(result, ClipboardApplyResult.skippedEmpty);
      expect(fake.writes, isEmpty);
      expect(sync.lastText, isNull);
    });

    test('文本保留原样写入：前后空格与换行不做 trim', () async {
      final _FakeClipboard fake = _FakeClipboard();
      final ClipboardSync sync = fake.sync();

      await sync.applyRemote('  缩进\n\n结束  ');

      expect(fake.writes, <String>['  缩进\n\n结束  ']);
    });

    test('开关关闭：返回 skippedOff，不写剪贴板也不改 lastText', () async {
      final _FakeClipboard fake = _FakeClipboard();
      final ClipboardSync sync = fake.sync();

      await sync.applyRemote('开着的值');
      sync.enabled = false;
      final ClipboardApplyResult result = await sync.applyRemote('关后的值');

      expect(sync.enabled, isFalse);
      expect(result, ClipboardApplyResult.skippedOff);
      expect(fake.writes, <String>['开着的值'], reason: '关闭后不得再写');
      expect(sync.lastText, '开着的值', reason: '关闭态不得改动已知值');
      expect(sync.lastSkip, ClipboardApplyResult.skippedOff);
    });

    test('写剪贴板抛异常：吞掉异常返回 skippedEmpty，且不污染已知值', () async {
      final _FakeClipboard fake = _FakeClipboard();
      final ClipboardSync sync = fake.sync();
      fake.writeThrows = true;

      final ClipboardApplyResult result = await sync.applyRemote('写不进去');

      expect(result, ClipboardApplyResult.skippedEmpty);
      expect(sync.lastText, isNull, reason: '写入失败就不能登记成已知值');
      // 恢复后再试同值仍能写入（不会被上面的失败误判成 skippedSame）
      fake.writeThrows = false;
      expect(await sync.applyRemote('写不进去'), ClipboardApplyResult.applied);
      expect(fake.writes, <String>['写不进去']);
    });
  });

  group('上行取值（takeLocalForUpload）', () {
    test('正常读取：返回文本并登记为已知值', () async {
      final _FakeClipboard fake = _FakeClipboard(readValue: '本机复制');
      final ClipboardSync sync = fake.sync();

      final String? text = await sync.takeLocalForUpload();

      expect(text, '本机复制');
      expect(sync.lastText, '本机复制');
    });

    test('同一内容连续取值只上行一次（第二次返回 null）', () async {
      final _FakeClipboard fake = _FakeClipboard(readValue: '不变的内容');
      final ClipboardSync sync = fake.sync();

      expect(await sync.takeLocalForUpload(), '不变的内容');
      expect(await sync.takeLocalForUpload(), isNull);
    });

    test('开关关闭：返回 null 且根本不读平台剪贴板', () async {
      final _FakeClipboard fake = _FakeClipboard(readValue: '不该被读');
      final ClipboardSync sync = fake.sync(enabled: false);

      expect(await sync.takeLocalForUpload(), isNull);
      expect(fake.reads, 0);
    });

    test('剪贴板为空或全空白：返回 null', () async {
      final _FakeClipboard fake = _FakeClipboard();
      final ClipboardSync sync = fake.sync();

      expect(await sync.takeLocalForUpload(), isNull);

      fake.readValue = '   \n ';
      expect(await sync.takeLocalForUpload(), isNull);
      expect(sync.lastText, isNull);
    });

    test('超过 maxChars：返回 null（不截断、不上行半截内容）', () async {
      final _FakeClipboard fake = _FakeClipboard(readValue: '123456');
      final ClipboardSync sync = fake.sync(maxChars: 5);

      expect(await sync.takeLocalForUpload(), isNull);
      expect(sync.lastText, isNull);
    });

    test('读取抛异常：不崩，返回 null', () async {
      final _FakeClipboard fake = _FakeClipboard(readValue: '读不到');
      fake.readThrows = true;
      final ClipboardSync sync = fake.sync();

      expect(await sync.takeLocalForUpload(), isNull);
      expect(fake.reads, 1);
    });

    test('上行后下游回声（同值）被 skippedSame：不覆盖本机剪贴板', () async {
      final _FakeClipboard fake = _FakeClipboard(readValue: 'A');
      final ClipboardSync sync = fake.sync();

      final String? uploaded = await sync.takeLocalForUpload();
      expect(uploaded, 'A');
      sync.markUploaded(uploaded!);

      final ClipboardApplyResult echo = await sync.applyRemote('A');
      expect(echo, ClipboardApplyResult.skippedSame);
      expect(fake.writes, isEmpty);
    });

    test('刚下行写入的内容不会被立刻上行回去（反向回声）', () async {
      final _FakeClipboard fake = _FakeClipboard();
      final ClipboardSync sync = fake.sync();

      await sync.applyRemote('被控端推来的');
      // 平台剪贴板此时已是该值，轮询读到同值必须丢弃
      fake.readValue = '被控端推来的';

      expect(await sync.takeLocalForUpload(), isNull);
    });
  });

  group('已知值与跳过原因', () {
    test('markUploaded 传空串不擦掉去重基线', () async {
      final ClipboardSync sync = ClipboardSync(
        readClipboard: () async => null,
        writeClipboard: (String text) async {},
      );

      await sync.applyRemote('基线');
      sync.markUploaded('');

      expect(sync.lastText, '基线');
    });

    test('成功写入会清掉上一次的跳过原因（UI 不需要自己重置）', () async {
      final _FakeClipboard fake = _FakeClipboard();
      final ClipboardSync sync = fake.sync();

      await sync.applyRemote('   ');
      expect(sync.lastSkip, ClipboardApplyResult.skippedEmpty);

      await sync.applyRemote('正常值');
      expect(sync.lastSkip, isNull);
    });

    test('enabled 可读可写，默认开启', () {
      final ClipboardSync sync = ClipboardSync(
        readClipboard: () async => null,
        writeClipboard: (String text) async {},
      );

      expect(sync.enabled, isTrue);
      sync.enabled = false;
      expect(sync.enabled, isFalse);
    });
  });
}
