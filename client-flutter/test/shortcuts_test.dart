import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/shortcuts.dart';

/// 便捷构造：无修饰键。
KeyChord plain(String key) => KeyChord(key: key);

/// 便捷构造：带修饰键。
KeyChord withMods(String key, Set<String> mods) =>
    KeyChord(key: key, modifiers: mods);

void main() {
  group('动作表', () {
    test('22 项齐全，enum 名即官方 key（补 screenshot / paste）', () {
      expect(ShortcutAction.values.length, 22);
      expect(
        ShortcutAction.values.map((ShortcutAction a) => a.name).toList(),
        <String>[
          'bossKey',
          'ctrlAltDelete',
          'fileTransfer',
          'floatingBall',
          'fullScreen',
          'lockMouse',
          'muteController',
          'networkStatus',
          'previousScreen',
          'nextScreen',
          'privacyMode',
          'privacyScreenSaver',
          'quitRemote',
          'remoteMouseMode',
          'smallWindowMode',
          'switchRemoteWindow',
          'viewMode',
          'viewModeToggle',
          'viewModeToggleAnnotation',
          'viewModeToggleToolbar',
          'screenshot',
          'paste',
        ],
      );
    });

    test('每项都有中文名与分组，分组只落在五个分节里', () {
      const Set<String> groups = <String>{'窗口', '输入', '画面', '观看', '其他'};
      for (final ShortcutAction a in ShortcutAction.values) {
        expect(a.label, isNotEmpty, reason: '${a.name} 缺 label');
        expect(a.group, isNotEmpty, reason: '${a.name} 缺 group');
        expect(groups.contains(a.group), isTrue, reason: '${a.name} 分组越界：${a.group}');
      }
      // 分组数量：窗口 5 / 输入 4 / 画面 5 / 观看 4 / 其他 4
      final Map<String, int> count = <String, int>{};
      for (final ShortcutAction a in ShortcutAction.values) {
        count[a.group] = (count[a.group] ?? 0) + 1;
      }
      expect(count, <String, int>{'窗口': 5, '输入': 4, '画面': 5, '观看': 4, '其他': 4});
    });

    test('分组归属与设计文档一致', () {
      expect(ShortcutAction.fullScreen.group, '窗口');
      expect(ShortcutAction.bossKey.group, '窗口');
      expect(ShortcutAction.paste.group, '输入');
      expect(ShortcutAction.ctrlAltDelete.group, '输入');
      expect(ShortcutAction.screenshot.group, '画面');
      expect(ShortcutAction.previousScreen.group, '画面');
      expect(ShortcutAction.viewModeToggleToolbar.group, '观看');
      expect(ShortcutAction.privacyScreenSaver.group, '其他');
    });

    test('needsPeer 只对被控端执行的动作置 true（8 项）', () {
      final List<String> peers = ShortcutAction.values
          .where((ShortcutAction a) => a.needsPeer)
          .map((ShortcutAction a) => a.name)
          .toList();
      expect(peers, <String>[
        'ctrlAltDelete',
        'fileTransfer',
        'muteController',
        'previousScreen',
        'nextScreen',
        'privacyMode',
        'privacyScreenSaver',
        'remoteMouseMode',
      ]);
      // 纯控制端行为不提示「需被控端支持」
      expect(ShortcutAction.fullScreen.needsPeer, isFalse);
      expect(ShortcutAction.bossKey.needsPeer, isFalse);
      expect(ShortcutAction.screenshot.needsPeer, isFalse);
    });
  });

  group('KeyChord.display', () {
    test('符号拼装：⌘⇧A / F11 / ⌘⌥Delete', () {
      expect(withMods('KeyA', <String>{'meta', 'shift'}).display, '⌘⇧A');
      expect(plain('F11').display, 'F11');
      expect(withMods('Delete', <String>{'meta', 'alt'}).display, '⌘⌥Delete');
    });

    test('顺序固定 meta→ctrl→alt→shift，与传入顺序无关', () {
      expect(
        withMods('KeyA', <String>{'shift', 'alt', 'ctrl', 'meta'}).display,
        '⌘⌃⌥⇧A',
      );
      expect(withMods('KeyA', <String>{'shift', 'meta'}).display, '⌘⇧A');
    });

    test('方向键画成箭头，四向都对', () {
      expect(withMods('ArrowLeft', <String>{'meta', 'shift'}).display, '⌘⇧←');
      expect(withMods('ArrowRight', <String>{'meta', 'shift'}).display, '⌘⇧→');
      expect(plain('ArrowUp').display, '↑');
      expect(plain('ArrowDown').display, '↓');
    });

    test('无修饰键时不会多出前缀，KeyA/Digit1 只留单字符', () {
      expect(plain('KeyV').display, 'V');
      expect(plain('F12').display, 'F12');
      expect(plain('KeyA').display, 'A');
      expect(plain('Digit1').display, '1');
      // 前缀后面不是单个字符时原样保留（Keypad 系列不能被误截）
      expect(plain('Numpad0').display, 'Numpad0');
      expect(plain('Keypad0').display, 'Keypad0');
    });
  });

  group('KeyChord.id 与相等性', () {
    test('修饰键按字母序拼接，顺序无关', () {
      expect(withMods('KeyA', <String>{'meta', 'alt'}).id, 'alt+meta+KeyA');
      expect(withMods('KeyA', <String>{'alt', 'meta'}).id, 'alt+meta+KeyA');
      expect(withMods('KeyA', <String>{'shift', 'meta'}).id, 'meta+shift+KeyA');
    });

    test('无修饰键时 id 就是主键本身', () {
      expect(plain('F11').id, 'F11');
    });

    test('id 相同即相等，hashCode 同步', () {
      final KeyChord a = withMods('KeyA', <String>{'meta', 'shift'});
      final KeyChord b = withMods('KeyA', <String>{'shift', 'meta'});
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
      expect(a == withMods('KeyA', <String>{'meta'}), isFalse);
      expect(a == plain('KeyA'), isFalse);
      // 塞进 Set 能去重
      expect(<KeyChord>{a, b}.length, 1);
    });

    test('未知修饰键被忽略（不污染 id 与 display）', () {
      final KeyChord dirty = withMods('KeyA', <String>{'meta', 'hyper'});
      expect(dirty.id, 'meta+KeyA');
      expect(dirty.display, '⌘A');
    });

    test('空主键 = isEmpty', () {
      expect(const KeyChord(key: '').isEmpty, isTrue);
      expect(plain('F11').isEmpty, isFalse);
    });
  });

  group('默认值表', () {
    test('13 项有出厂默认，其余 9 项不绑定', () {
      expect(ShortcutMap.defaults.length, 13);
      final ShortcutMap map = ShortcutMap();
      // 指定的默认键位
      expect(map.chordOf(ShortcutAction.fullScreen)!.display, 'F11');
      expect(map.chordOf(ShortcutAction.quitRemote)!.display, '⌘⇧Q');
      expect(map.chordOf(ShortcutAction.ctrlAltDelete)!.display, '⌘⌥Delete');
      expect(map.chordOf(ShortcutAction.muteController)!.display, '⌘⇧M');
      expect(map.chordOf(ShortcutAction.networkStatus)!.display, '⌘⇧N');
      expect(map.chordOf(ShortcutAction.previousScreen)!.display, '⌘⇧←');
      expect(map.chordOf(ShortcutAction.nextScreen)!.display, '⌘⇧→');
      expect(map.chordOf(ShortcutAction.viewModeToggle)!.display, '⌘⇧V');
      expect(map.chordOf(ShortcutAction.viewModeToggleAnnotation)!.display, '⌘⇧A');
      expect(map.chordOf(ShortcutAction.viewModeToggleToolbar)!.display, '⌘⇧T');
      expect(map.chordOf(ShortcutAction.smallWindowMode)!.display, '⌘⇧W');
      expect(map.chordOf(ShortcutAction.paste)!.display, '⌘V');
      expect(map.chordOf(ShortcutAction.screenshot)!.display, '⌘⇧S');
    });

    test('留给用户自己设的 9 项默认是未绑定', () {
      final ShortcutMap map = ShortcutMap();
      const List<ShortcutAction> unbound = <ShortcutAction>[
        ShortcutAction.bossKey,
        ShortcutAction.fileTransfer,
        ShortcutAction.floatingBall,
        ShortcutAction.lockMouse,
        ShortcutAction.privacyMode,
        ShortcutAction.privacyScreenSaver,
        ShortcutAction.remoteMouseMode,
        ShortcutAction.switchRemoteWindow,
        ShortcutAction.viewMode,
      ];
      for (final ShortcutAction a in unbound) {
        expect(map.chordOf(a), isNull, reason: '${a.name} 不该有默认键');
        expect(ShortcutMap.defaults.containsKey(a), isFalse);
      }
    });

    test('出厂默认之间没有冲突，且都不是系统保留组合', () {
      final Map<String, ShortcutAction> seen = <String, ShortcutAction>{};
      ShortcutMap.defaults.forEach((ShortcutAction action, KeyChord chord) {
        expect(seen.containsKey(chord.id), isFalse,
            reason: '${action.name} 与 ${seen[chord.id]?.name} 默认为同一组合');
        seen[chord.id] = action;
        expect(ReservedChords.isReserved(chord), isFalse,
            reason: '${action.name} 的默认值撞了系统保留键');
      });
    });

    test('全新配置没有定制项', () {
      final ShortcutMap map = ShortcutMap();
      expect(map.hasCustom, isFalse);
      for (final ShortcutAction a in ShortcutAction.values) {
        expect(map.isDefault(a), isTrue, reason: '${a.name} 应为默认');
      }
    });
  });

  group('set 与冲突检测', () {
    test('撞别的动作：返回占用者且不写入', () {
      final ShortcutMap map = ShortcutMap();
      final KeyChord vKey = withMods('KeyV', <String>{'meta', 'shift'});
      // ⌘⇧V 已被 viewModeToggle 占用
      final ShortcutAction? owner = map.set(ShortcutAction.screenshot, vKey);
      expect(owner, ShortcutAction.viewModeToggle);
      expect(map.chordOf(ShortcutAction.screenshot)!.id, 'meta+shift+KeyS');
    });

    test('conflictOf 不含自己：设成自己当前值不算冲突', () {
      final ShortcutMap map = ShortcutMap();
      final KeyChord f11 = plain('F11');
      expect(map.conflictOf(ShortcutAction.fullScreen, f11), isNull);
      expect(map.set(ShortcutAction.fullScreen, f11), isNull);
      expect(map.chordOf(ShortcutAction.fullScreen)!.id, 'F11');
    });

    test('设成空闲组合：写入并返回 null', () {
      final ShortcutMap map = ShortcutMap();
      expect(map.set(ShortcutAction.bossKey, withMods('KeyB', <String>{'meta', 'alt'})),
          isNull);
      expect(map.chordOf(ShortcutAction.bossKey)!.display, '⌘⌥B');
      expect(map.hasCustom, isTrue);
      expect(map.isDefault(ShortcutAction.bossKey), isFalse);
    });

    test('修改时把别人的键让出来：旧组合不再被自己占用', () {
      final ShortcutMap map = ShortcutMap();
      map.set(ShortcutAction.screenshot, plain('F12'));
      expect(map.actionFor(plain('F12')), ShortcutAction.screenshot);
      // 原来 ⌘⇧S 只有它自己用，改走后应无主
      expect(map.actionFor(withMods('KeyS', <String>{'meta', 'shift'})), isNull);
    });

    test('被清空的动作不再参与冲突判定', () {
      final ShortcutMap map = ShortcutMap();
      map.clear(ShortcutAction.viewModeToggle);
      expect(map.set(ShortcutAction.screenshot, withMods('KeyV', <String>{'meta', 'shift'})),
          isNull);
      expect(map.chordOf(ShortcutAction.screenshot)!.display, '⌘⇧V');
    });
  });

  group('clear / reset / resetAll', () {
    test('clear 后 chordOf 为 null、isDefault 为 false', () {
      final ShortcutMap map = ShortcutMap();
      map.clear(ShortcutAction.paste);
      expect(map.chordOf(ShortcutAction.paste), isNull);
      expect(map.isDefault(ShortcutAction.paste), isFalse);
      expect(map.hasCustom, isTrue);
      expect(map.actionFor(withMods('KeyV', <String>{'meta'})), isNull);
    });

    test('默认未绑定的动作被 clear 仍是「默认未绑定」', () {
      final ShortcutMap map = ShortcutMap();
      map.clear(ShortcutAction.bossKey);
      expect(map.chordOf(ShortcutAction.bossKey), isNull);
      expect(map.isDefault(ShortcutAction.bossKey), isTrue);
    });

    test('reset 单项回到默认', () {
      final ShortcutMap map = ShortcutMap();
      map.set(ShortcutAction.paste, plain('F9'));
      expect(map.isDefault(ShortcutAction.paste), isFalse);
      map.reset(ShortcutAction.paste);
      expect(map.chordOf(ShortcutAction.paste)!.display, '⌘V');
      expect(map.isDefault(ShortcutAction.paste), isTrue);
    });

    test('reset 也能恢复被 clear 掉的项', () {
      final ShortcutMap map = ShortcutMap();
      map.clear(ShortcutAction.fullScreen);
      map.reset(ShortcutAction.fullScreen);
      expect(map.chordOf(ShortcutAction.fullScreen)!.display, 'F11');
    });

    test('resetAll 后 hasCustom 为 false', () {
      final ShortcutMap map = ShortcutMap();
      map.set(ShortcutAction.bossKey, plain('F8'));
      map.clear(ShortcutAction.screenshot);
      expect(map.hasCustom, isTrue);
      map.resetAll();
      expect(map.hasCustom, isFalse);
      expect(map.chordOf(ShortcutAction.screenshot)!.display, '⌘⇧S');
    });
  });

  group('actionFor 反查', () {
    test('已绑定的组合能查到动作', () {
      final ShortcutMap map = ShortcutMap();
      expect(map.actionFor(withMods('KeyQ', <String>{'meta', 'shift'})),
          ShortcutAction.quitRemote);
      expect(map.actionFor(plain('F11')), ShortcutAction.fullScreen);
    });

    test('未绑定/空闲组合返回 null', () {
      final ShortcutMap map = ShortcutMap();
      expect(map.actionFor(withMods('KeyZ', <String>{'meta', 'shift'})), isNull);
      expect(map.actionFor(const KeyChord(key: '')), isNull);
    });
  });

  group('record 录制解析', () {
    test('正常组合 → ok 且带 chord', () {
      final RecordOutcome out = ShortcutMap.record(
        keyLabel: 'KeyA',
        modifiers: <String>{'meta', 'shift'},
        isModifierOnly: false,
      );
      expect(out.verdict, RecordVerdict.ok);
      expect(out.chord!.display, '⌘⇧A');
      expect(out.chord!.id, 'meta+shift+KeyA');
    });

    test('只按修饰键 → modifierOnly，不报错', () {
      final RecordOutcome out = ShortcutMap.record(
        keyLabel: 'MetaLeft',
        modifiers: <String>{'meta'},
        isModifierOnly: true,
      );
      expect(out.verdict, RecordVerdict.modifierOnly);
      expect(out.chord, isNull);
      expect(out.verdict.message, '');
    });

    test('无修饰键的 Backspace / Delete → clear', () {
      for (final String k in <String>['Backspace', 'Delete']) {
        final RecordOutcome out = ShortcutMap.record(
          keyLabel: k,
          modifiers: <String>{},
          isModifierOnly: false,
        );
        expect(out.verdict, RecordVerdict.clear, reason: k);
        expect(out.chord, isNull);
        expect(out.verdict.message, '');
      }
    });

    test('带修饰键的 Delete 是正常组合（⌘⌥Delete 可用）', () {
      final RecordOutcome out = ShortcutMap.record(
        keyLabel: 'Delete',
        modifiers: <String>{'meta', 'alt'},
        isModifierOnly: false,
      );
      expect(out.verdict, RecordVerdict.ok);
      expect(out.chord!.display, '⌘⌥Delete');
    });

    test('系统保留组合 → invalid，文案「该按键不可设置」', () {
      final RecordOutcome out = ShortcutMap.record(
        keyLabel: 'KeyQ',
        modifiers: <String>{'meta'},
        isModifierOnly: false,
      );
      expect(out.verdict, RecordVerdict.invalid);
      expect(out.verdict.message, '该按键不可设置');
      expect(out.chord, isNull);
    });

    test('空 keyLabel → invalid', () {
      final RecordOutcome out = ShortcutMap.record(
        keyLabel: '',
        modifiers: <String>{'meta'},
        isModifierOnly: false,
      );
      expect(out.verdict, RecordVerdict.invalid);
      expect(out.verdict.message, '该按键不可设置');
    });

    test('modifierOnly 优先于空 keyLabel（中间态不报错）', () {
      final RecordOutcome out = ShortcutMap.record(
        keyLabel: '',
        modifiers: <String>{'shift'},
        isModifierOnly: true,
      );
      expect(out.verdict, RecordVerdict.modifierOnly);
    });

    test('修饰键大小写与未知修饰键被规范化', () {
      final RecordOutcome out = ShortcutMap.record(
        keyLabel: 'KeyA',
        modifiers: <String>{'Meta', 'hyper'},
        isModifierOnly: false,
      );
      expect(out.verdict, RecordVerdict.ok);
      expect(out.chord!.id, 'meta+KeyA');
    });

    test('字母键归一：keyLabel 的小写 a 与 KeyA 是同一个键', () {
      // LogicalKeyboardKey.keyLabel 对字母返回小写，不归一会和默认表对不上
      final RecordOutcome lower = ShortcutMap.record(
        keyLabel: 'a',
        modifiers: <String>{'meta', 'shift'},
        isModifierOnly: false,
      );
      expect(lower.verdict, RecordVerdict.ok);
      expect(lower.chord!.id, 'meta+shift+KeyA');
      expect(lower.chord!.display, '⌘⇧A');

      final ShortcutMap map = ShortcutMap();
      expect(map.actionFor(lower.chord!), ShortcutAction.viewModeToggleAnnotation);
      // 录 ⌘⇧v（小写）会撞上 viewModeToggle 的 ⌘⇧V
      final RecordOutcome v = ShortcutMap.record(
        keyLabel: 'v',
        modifiers: <String>{'meta', 'shift'},
        isModifierOnly: false,
      );
      expect(map.set(ShortcutAction.screenshot, v.chord!), ShortcutAction.viewModeToggle);
    });

    test('录制结果可直接喂给 set', () {
      final ShortcutMap map = ShortcutMap();
      final RecordOutcome out = ShortcutMap.record(
        keyLabel: 'KeyB',
        modifiers: <String>{'alt', 'meta'},
        isModifierOnly: false,
      );
      expect(map.set(ShortcutAction.bossKey, out.chord!), isNull);
      expect(map.actionFor(out.chord!), ShortcutAction.bossKey);
    });
  });

  group('ReservedChords', () {
    test('五条系统保留组合全部命中', () {
      expect(ReservedChords.isReserved(withMods('KeyQ', <String>{'meta'})), isTrue);
      // 主键写成 'Q' 也一样拦
      expect(ReservedChords.isReserved(withMods('Q', <String>{'meta'})), isTrue);
      expect(ReservedChords.isReserved(withMods('Tab', <String>{'meta'})), isTrue);
      expect(ReservedChords.isReserved(withMods('Space', <String>{'meta'})), isTrue);
      expect(ReservedChords.isReserved(withMods('F4', <String>{'alt'})), isTrue);
      expect(
        ReservedChords.isReserved(withMods('Delete', <String>{'ctrl', 'alt'})),
        isTrue,
      );
    });

    test('本工程默认值不落在保留集合里', () {
      // ⌘⇧Q ≠ ⌘Q
      expect(ReservedChords.isReserved(withMods('KeyQ', <String>{'meta', 'shift'})),
          isFalse);
      // ⌘⌥Delete ≠ Ctrl+Alt+Delete
      expect(ReservedChords.isReserved(withMods('Delete', <String>{'meta', 'alt'})),
          isFalse);
    });

    test('普通组合与裸键都放行', () {
      expect(ReservedChords.isReserved(plain('F11')), isFalse);
      expect(ReservedChords.isReserved(plain('KeyQ')), isFalse);
      expect(ReservedChords.isReserved(withMods('KeyV', <String>{'meta'})), isFalse);
      expect(ReservedChords.isReserved(withMods('F4', <String>{'meta'})), isFalse);
    });
  });

  group('序列化', () {
    test('KeyChord.toJson 只写 key 与规范化后的修饰键', () {
      final Map<String, dynamic> json =
          withMods('KeyA', <String>{'shift', 'meta'}).toJson();
      expect(json['key'], 'KeyA');
      expect(json['modifiers'], <String>['meta', 'shift']);
    });

    test('ShortcutMap 往返保留定制与「已删除」两种状态', () {
      final ShortcutMap map = ShortcutMap();
      map.set(ShortcutAction.bossKey, withMods('KeyB', <String>{'meta', 'alt'}));
      map.set(ShortcutAction.fullScreen, plain('F12'));
      map.clear(ShortcutAction.paste);

      final ShortcutMap back = ShortcutMap.fromJson(map.toJson());
      expect(back.chordOf(ShortcutAction.bossKey)!.display, '⌘⌥B');
      expect(back.chordOf(ShortcutAction.fullScreen)!.display, 'F12');
      expect(back.chordOf(ShortcutAction.paste), isNull);
      // 没动过的项仍跟随默认
      expect(back.chordOf(ShortcutAction.screenshot)!.display, '⌘⇧S');
      expect(back.hasCustom, isTrue);
      expect(back.actionFor(withMods('KeyB', <String>{'alt', 'meta'})),
          ShortcutAction.bossKey);
    });

    test('默认配置往返后仍是全默认', () {
      final ShortcutMap back = ShortcutMap.fromJson(ShortcutMap().toJson());
      expect(back.hasCustom, isFalse);
      expect(back.chordOf(ShortcutAction.fullScreen)!.display, 'F11');
    });

    test('fromJson(null) 回落全默认', () {
      final ShortcutMap back = ShortcutMap.fromJson(null);
      expect(back.hasCustom, isFalse);
      expect(ShortcutMap.defaults.length, 13);
    });

    test('fromJson 垃圾数据不抛，全部跳过', () {
      final List<Map<String, dynamic>?> garbage = <Map<String, dynamic>?>[
        <String, dynamic>{},
        <String, dynamic>{'bindings': 42},
        <String, dynamic>{'bindings': 'oops'},
        <String, dynamic>{'bindings': <Object?>[]},
        <String, dynamic>{
          'bindings': <String, dynamic>{'nopeAction': <String, dynamic>{'key': 'KeyA'}},
        },
        <String, dynamic>{
          'bindings': <String, dynamic>{'bossKey': 'KeyA'},
        },
        <String, dynamic>{
          'bindings': <String, dynamic>{
            'bossKey': <String, dynamic>{'key': 42},
          },
        },
        <String, dynamic>{
          'bindings': <String, dynamic>{
            'bossKey': <String, dynamic>{'key': ''},
          },
        },
        <String, dynamic>{
          'bindings': <Object?, Object?>{1: <String, dynamic>{'key': 'KeyA'}},
        },
      ];
      for (final Map<String, dynamic>? json in garbage) {
        late ShortcutMap map;
        expect(() => map = ShortcutMap.fromJson(json), returnsNormally);
        expect(map.hasCustom, isFalse);
        expect(map.chordOf(ShortcutAction.fullScreen)!.display, 'F11');
      }
    });

    test('bindings 里的 null 表示用户删过 → 解析为未绑定', () {
      final ShortcutMap map = ShortcutMap.fromJson(<String, dynamic>{
        'bindings': <String, dynamic>{'fullScreen': null},
      });
      expect(map.chordOf(ShortcutAction.fullScreen), isNull);
      expect(map.isDefault(ShortcutAction.fullScreen), isFalse);
    });

    test('手改配置的重复组合：先到先得，不产生歧义', () {
      final ShortcutMap map = ShortcutMap.fromJson(<String, dynamic>{
        'bindings': <String, dynamic>{
          'fullScreen': <String, dynamic>{'key': 'KeyX'},
          'bossKey': <String, dynamic>{'key': 'KeyX'},
        },
      });
      expect(map.chordOf(ShortcutAction.fullScreen)!.display, 'X');
      expect(map.chordOf(ShortcutAction.bossKey), isNull);
      expect(map.actionFor(plain('KeyX')), ShortcutAction.fullScreen);
    });

    test('KeyChord.fromJson 容错：缺字段/类型不对 → 空组合', () {
      expect(KeyChord.fromJson(<String, dynamic>{}).isEmpty, isTrue);
      expect(KeyChord.fromJson(<String, dynamic>{}).display, '');
      expect(
        KeyChord.fromJson(<String, dynamic>{'key': 'KeyA', 'modifiers': 'meta'}).id,
        'KeyA',
      );
      expect(
        KeyChord.fromJson(<String, dynamic>{
          'key': 'KeyA',
          'modifiers': <Object?>['META', null, 7, 'shift'],
        }).id,
        'meta+shift+KeyA',
      );
    });
  });
}
