import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/connect_stage.dart';

/// 判断文案是中文：至少含一个 CJK 汉字，且不含 ASCII 字母串以外的占位。
bool _isChinese(String text) => RegExp(r'[\u4e00-\u9fa5]').hasMatch(text);

void main() {
  group('阶段文案与语义', () {
    test('7 个阶段顺序固定为 init→buildServer→syncInfo→setting→optimized→transmitting→success', () {
      expect(
        ConnectStage.values.take(7).toList(),
        <ConnectStage>[
          ConnectStage.init,
          ConnectStage.buildServer,
          ConnectStage.syncInfo,
          ConnectStage.setting,
          ConnectStage.optimized,
          ConnectStage.transmitting,
          ConnectStage.success,
        ],
      );
      expect(ConnectStage.values.last, ConnectStage.failed);
    });

    test('每个阶段的 label/hint 都非空且是中文', () {
      for (final ConnectStage s in ConnectStage.values) {
        expect(s.label, isNotEmpty, reason: '${s.name} 缺 label');
        expect(s.hint, isNotEmpty, reason: '${s.name} 缺 hint');
        expect(_isChinese(s.label), isTrue, reason: '${s.name} 的 label 不是中文：${s.label}');
        expect(_isChinese(s.hint), isTrue, reason: '${s.name} 的 hint 不是中文：${s.hint}');
      }
    });

    test('isBusy 除 success/failed 外都为 true，isReady 仅 success', () {
      for (final ConnectStage s in ConnectStage.values) {
        final bool done = s == ConnectStage.success || s == ConnectStage.failed;
        expect(s.isBusy, !done, reason: s.name);
        expect(s.isReady, s == ConnectStage.success, reason: s.name);
      }
    });
  });

  group('正常推进', () {
    test('从 init 一路推进到 success，ratio 0.0→1.0 单调不减', () {
      final ConnectProgress p = ConnectProgress();
      expect(p.stage, ConnectStage.init);
      expect(p.ratio, 0.0);
      expect(p.failure, isNull);

      double last = p.ratio;
      for (final ConnectStage s in ConnectStage.values.take(7)) {
        p.go(s);
        expect(p.stage, s);
        expect(p.ratio, greaterThanOrEqualTo(last));
        last = p.ratio;
      }
      expect(p.stage, ConnectStage.success);
      expect(p.ratio, 1.0);
      expect(p.stage.isReady, isTrue);
      expect(p.stage.isBusy, isFalse);
    });

    test('中间的每个阶段 ratio 都落在 0–1 之间', () {
      final ConnectProgress p = ConnectProgress();
      for (final ConnectStage s in ConnectStage.values.take(7)) {
        p.go(s);
        expect(p.ratio, inInclusiveRange(0.0, 1.0), reason: s.name);
      }
    });
  });

  group('乱序与幂等', () {
    test('后退被忽略：transmitting 之后再来 setting 保持不变', () {
      final ConnectProgress p = ConnectProgress();
      p.go(ConnectStage.transmitting);
      final double before = p.ratio;
      p.go(ConnectStage.setting);
      expect(p.stage, ConnectStage.transmitting);
      expect(p.ratio, before);
    });

    test('迟到的早期事件不会把 UI 拽回去（success 后收到 buildServer）', () {
      final ConnectProgress p = ConnectProgress();
      p.go(ConnectStage.success);
      p.go(ConnectStage.buildServer);
      expect(p.stage, ConnectStage.success);
      expect(p.ratio, 1.0);
    });

    test('重复 go 同一阶段幂等，ratio 不变', () {
      final ConnectProgress p = ConnectProgress();
      p.go(ConnectStage.syncInfo);
      final double first = p.ratio;
      p.go(ConnectStage.syncInfo);
      p.go(ConnectStage.syncInfo);
      expect(p.stage, ConnectStage.syncInfo);
      expect(p.ratio, first);
    });

    test('初始状态重复 go(init) 也不动 ratio', () {
      final ConnectProgress p = ConnectProgress();
      p.go(ConnectStage.init);
      expect(p.stage, ConnectStage.init);
      expect(p.ratio, 0.0);
    });
  });

  group('失败', () {
    test('go(failed) 被拒绝：失败只能走 fail()', () {
      final ConnectProgress p = ConnectProgress();
      p.go(ConnectStage.setting);
      p.go(ConnectStage.failed);
      expect(p.stage, ConnectStage.setting);
      expect(p.failure, isNull);
      expect(p.ratio, ConnectStage.setting.index / 6);
    });

    test('fail 落到 failed 并保留失败前的 ratio', () {
      final ConnectProgress p = ConnectProgress();
      p.go(ConnectStage.optimized);
      final double before = p.ratio;
      p.fail('WebRTC 协商超时');
      expect(p.stage, ConnectStage.failed);
      expect(p.failure, 'WebRTC 协商超时');
      expect(p.ratio, before);
      expect(p.stage.isBusy, isFalse);
      expect(p.stage.isReady, isFalse);
    });

    test('fail 传空串时给默认中文文案，不留空', () {
      final ConnectProgress p = ConnectProgress();
      p.go(ConnectStage.syncInfo);
      p.fail('');
      expect(p.stage, ConnectStage.failed);
      expect(p.failure, isNotNull);
      expect(p.failure!.isNotEmpty, isTrue);
      expect(_isChinese(p.failure!), isTrue);
    });

    test('fail 传纯空白也按空串处理', () {
      final ConnectProgress p = ConnectProgress();
      p.fail('   ');
      expect(p.failure!.isNotEmpty, isTrue);
      expect(p.failure!.trim(), p.failure);
    });

    test('失败后 go 被忽略，必须先 reset', () {
      final ConnectProgress p = ConnectProgress();
      p.go(ConnectStage.setting);
      p.fail('连接被拒绝');
      p.go(ConnectStage.transmitting);
      expect(p.stage, ConnectStage.failed);
      expect(p.failure, '连接被拒绝');
    });
  });

  group('重置', () {
    test('reset 回到 init，failure 清空，ratio 归 0', () {
      final ConnectProgress p = ConnectProgress();
      p.go(ConnectStage.transmitting);
      p.fail('断流');
      p.reset();
      expect(p.stage, ConnectStage.init);
      expect(p.failure, isNull);
      expect(p.ratio, 0.0);
      expect(p.stage.isBusy, isTrue);
    });

    test('reset 后可以重新推进到 success', () {
      final ConnectProgress p = ConnectProgress();
      p.go(ConnectStage.success);
      p.reset();
      p.go(ConnectStage.buildServer);
      expect(p.stage, ConnectStage.buildServer);
      p.go(ConnectStage.success);
      expect(p.ratio, 1.0);
    });
  });
}
