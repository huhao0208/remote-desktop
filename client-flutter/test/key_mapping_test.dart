import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/key_mapping.dart';

void main() {
  group('normalizeOs', () {
    test('macOS 的各种写法都归一成 macos', () {
      for (final String raw in <String>[
        'macOS',
        'macos',
        'darwin',
        'mac',
        'Mac OS X',
        'osx',
      ]) {
        expect(KeyMapper.normalizeOs(raw), KeyMapper.macos, reason: raw);
      }
    });

    test('Windows 的各种写法都归一成 windows', () {
      for (final String raw in <String>['win32', 'Windows', 'WINDOWS', 'win']) {
        expect(KeyMapper.normalizeOs(raw), KeyMapper.windows, reason: raw);
      }
    });

    test('其余（linux / 空串 / 未知）一律归 linux', () {
      for (final String raw in <String>['linux', '', '  linux6  ', 'android']) {
        expect(KeyMapper.normalizeOs(raw), KeyMapper.linux, reason: raw);
      }
    });

    test("darwin 里含 'win' 也不能被认成 Windows", () {
      expect(KeyMapper.normalizeOs('darwin'), isNot(KeyMapper.windows));
    });
  });

  group('isCrossPlatform', () {
    test('macOS ↔ Windows 双向都是跨平台', () {
      expect(KeyMapper.isCrossPlatform('macos', 'win32'), isTrue);
      expect(KeyMapper.isCrossPlatform('darwin', 'Windows'), isTrue);
    });

    test('同平台不算跨平台', () {
      expect(KeyMapper.isCrossPlatform('macos', 'macos'), isFalse);
      expect(KeyMapper.isCrossPlatform('win32', 'windows'), isFalse);
    });

    test('Linux 任一端都不算跨平台（直通）', () {
      expect(KeyMapper.isCrossPlatform('linux', 'windows'), isFalse);
      expect(KeyMapper.isCrossPlatform('macos', 'linux'), isFalse);
      expect(KeyMapper.isCrossPlatform('linux', 'linux'), isFalse);
    });
  });

  group('macOS → Windows', () {
    const KeyMappingConfig def = KeyMappingConfig();
    const KeyMappingConfig asCtrl = KeyMappingConfig(cmdAs: CmdTarget.ctrl);

    String map(String key, [KeyMappingConfig config = def]) => KeyMapper.mapKey(
      key,
      localOs: 'macos',
      remoteOs: 'win32',
      config: config,
    );

    test('⌘（词表名 win）默认映射成 win', () {
      expect(map('win'), 'win');
    });

    test('cmdAs: ctrl 时 ⌘ 映射成 ctrl', () {
      expect(map('win', asCtrl), 'ctrl');
    });

    test('⌥（alt）→ alt，词表不变', () {
      expect(map('alt'), 'alt');
    });

    test('delete → backspace（mac 的 Delete 就是退格）', () {
      expect(map('delete'), 'backspace');
    });

    test('deleteAsBackspace: false 时保持 delete', () {
      expect(
        map('delete', const KeyMappingConfig(deleteAsBackspace: false)),
        'delete',
      );
    });

    test('普通键（enter / esc / a）原样直通', () {
      expect(map('enter'), 'enter');
      expect(map('esc'), 'esc');
      expect(map('a'), 'a');
      expect(map('backspace'), 'backspace');
    });

    test('未知键原样直通，不臆造映射', () {
      expect(map('f13'), 'f13');
      expect(map('some_unknown_key'), 'some_unknown_key');
    });
  });

  group('Windows → macOS', () {
    const KeyMappingConfig config = KeyMappingConfig();

    String map(String key) => KeyMapper.mapKey(
      key,
      localOs: 'win32',
      remoteOs: 'macOS',
      config: config,
    );

    test('Win → win（协议词表里 ⌘ 仍叫 win，不产出 cmd/command）', () {
      expect(map('win'), 'win');
      expect(map('win'), isNot('cmd'));
      expect(map('win'), isNot('command'));
    });

    test('Alt → alt（⌥ 在词表里仍叫 alt，不产出 option）', () {
      expect(map('alt'), 'alt');
      expect(map('alt'), isNot('option'));
    });

    test('delete 在 win→mac 表里没有规则，原样返回', () {
      expect(map('delete'), 'delete');
    });

    test('普通键与未知键原样直通', () {
      expect(map('ctrl'), 'ctrl');
      expect(map('enter'), 'enter');
      expect(map('z'), 'z');
      expect(map('nope'), 'nope');
    });
  });

  group('同平台 / Linux 直通', () {
    test('mac → mac：⌘ 与 delete 都不动', () {
      const KeyMappingConfig config = KeyMappingConfig(cmdAs: CmdTarget.ctrl);
      expect(
        KeyMapper.mapKey(
          'win',
          localOs: 'macos',
          remoteOs: 'darwin',
          config: config,
        ),
        'win',
      );
      expect(
        KeyMapper.mapKey(
          'delete',
          localOs: 'macos',
          remoteOs: 'macos',
          config: config,
        ),
        'delete',
      );
    });

    test('win → linux：直通，即便另一端是 windows 写法也不映射', () {
      const KeyMappingConfig config = KeyMappingConfig();
      expect(
        KeyMapper.mapKey(
          'win',
          localOs: 'win32',
          remoteOs: 'linux',
          config: config,
        ),
        'win',
      );
      expect(
        KeyMapper.mapKey(
          'delete',
          localOs: 'linux',
          remoteOs: 'win32',
          config: config,
        ),
        'delete',
      );
    });
  });

  group('KeyMappingConfig', () {
    test('默认：⌘ → Win，Delete → Backspace', () {
      const KeyMappingConfig c = KeyMappingConfig();
      expect(c.cmdAs, CmdTarget.win);
      expect(c.deleteAsBackspace, isTrue);
    });

    test('copyWith 只改传入字段', () {
      const KeyMappingConfig base = KeyMappingConfig();
      final KeyMappingConfig next = base.copyWith(cmdAs: CmdTarget.ctrl);
      expect(next.cmdAs, CmdTarget.ctrl);
      expect(next.deleteAsBackspace, isTrue);
      expect(base.cmdAs, CmdTarget.win);
    });

    test('toJson / fromJson 往返一致', () {
      const KeyMappingConfig c = KeyMappingConfig(
        cmdAs: CmdTarget.ctrl,
        deleteAsBackspace: false,
      );
      final KeyMappingConfig back = KeyMappingConfig.fromJson(c.toJson());
      expect(back.cmdAs, CmdTarget.ctrl);
      expect(back.deleteAsBackspace, isFalse);
    });

    test('fromJson：空 JSON / 脏值退默认', () {
      final KeyMappingConfig empty = KeyMappingConfig.fromJson(
        <String, dynamic>{},
      );
      expect(empty.cmdAs, CmdTarget.win);
      expect(empty.deleteAsBackspace, isTrue);

      final KeyMappingConfig dirty = KeyMappingConfig.fromJson(
        <String, dynamic>{'cmdAs': 'super', 'deleteAsBackspace': 'yes'},
      );
      expect(dirty.cmdAs, CmdTarget.win);
      expect(dirty.deleteAsBackspace, isTrue);
    });

    test('CmdTarget 两个取值都有中文标签', () {
      expect(CmdTarget.win.label, isNotEmpty);
      expect(CmdTarget.ctrl.label, isNotEmpty);
      expect(CmdTarget.win.label, isNot(CmdTarget.ctrl.label));
    });
  });

  group('describeMapping', () {
    test('跨平台：文案非空，且随 cmdAs 变化', () {
      final String win = describeMapping(
        'macos',
        'win32',
        const KeyMappingConfig(),
      );
      final String ctrl = describeMapping(
        'macos',
        'win32',
        const KeyMappingConfig(cmdAs: CmdTarget.ctrl),
      );
      expect(win, isNotEmpty);
      expect(ctrl, isNotEmpty);
      expect(win, isNot(ctrl));
      // 关掉 delete 映射后说明里不该再提 Backspace
      final String noDelete = describeMapping(
        'macos',
        'win32',
        const KeyMappingConfig(deleteAsBackspace: false),
      );
      expect(noDelete.contains('Backspace'), isFalse);
    });

    test('Windows → macOS 也给出具体映射说明', () {
      final String text = describeMapping(
        'win32',
        'macos',
        const KeyMappingConfig(),
      );
      expect(text, isNotEmpty);
      expect(text.contains('⌘'), isTrue);
    });

    test('同平台 / Linux 文案与跨平台不同，且同样非空', () {
      const KeyMappingConfig config = KeyMappingConfig();
      final String same = describeMapping('macos', 'macos', config);
      final String linux = describeMapping('linux', 'win32', config);
      final String cross = describeMapping('macos', 'win32', config);
      expect(same, isNotEmpty);
      expect(linux, isNotEmpty);
      expect(same, isNot(cross));
      expect(linux, isNot(cross));
    });
  });
}
