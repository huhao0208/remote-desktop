/// 22 项可配置快捷键的纯逻辑层：动作表 / 按键组合 / 冲突检测 / 录制解析。
///
/// 为什么单独成文件、且不 import flutter：设置页和远控页都要用到这套规则，
/// 如果放在 widget 层就会把「按键规范化、冲突判定」和 UI 生命周期绑死，
/// 也没法在无设备环境里跑单测。这里只用 `dart:core`，主控把
/// `LogicalKeyboardKey.keyLabel` 和按下瞬间的修饰键状态转成字符串传进来。
library;

/// 22 个可配置动作。enum 名即官方 key 的 camelCase 形式。
///
/// 官方 B6.1 列了 20 项，本工程补 `screenshot`（远程截图）与 `paste`
/// （粘贴剪贴板）两项凑满 22——这两项是远控高频操作，官方把它们放在工具栏
/// 而非快捷键页，但对键盘党来说更需要可配置。
enum ShortcutAction {
  bossKey,
  ctrlAltDelete,
  fileTransfer,
  floatingBall,
  fullScreen,
  lockMouse,
  muteController,
  networkStatus,
  previousScreen,
  nextScreen,
  privacyMode,
  privacyScreenSaver,
  quitRemote,
  remoteMouseMode,
  smallWindowMode,
  switchRemoteWindow,
  viewMode,
  viewModeToggle,
  viewModeToggleAnnotation,
  viewModeToggleToolbar,
  screenshot,
  paste;

  /// 中文名，如「远控窗口全屏/窗口化」。
  ///
  /// 文案直接取官方设置页的条目名，便于和文档逐条对照。
  String get label {
    switch (this) {
      case ShortcutAction.bossKey:
        return '老板键（隐藏/显示所有客户端窗口）';
      case ShortcutAction.ctrlAltDelete:
        return '发送 Ctrl+Alt+Delete';
      case ShortcutAction.fileTransfer:
        return '打开文件传输';
      case ShortcutAction.floatingBall:
        return '显示/隐藏悬浮球';
      case ShortcutAction.fullScreen:
        return '远控窗口全屏/窗口化';
      case ShortcutAction.lockMouse:
        return '锁定鼠标在远控窗口中';
      case ShortcutAction.muteController:
        return '静音/取消静音';
      case ShortcutAction.networkStatus:
        return '显示/隐藏网络状态';
      case ShortcutAction.previousScreen:
        return '切换上一个屏幕';
      case ShortcutAction.nextScreen:
        return '切换下一个屏幕';
      case ShortcutAction.privacyMode:
        return '被控时解除防窥模式';
      case ShortcutAction.privacyScreenSaver:
        return '开启/关闭隐私屏保';
      case ShortcutAction.quitRemote:
        return '立即退出远控';
      case ShortcutAction.remoteMouseMode:
        return '使用被控端鼠标/解锁鼠标';
      case ShortcutAction.smallWindowMode:
        return '进入/退出小窗模式';
      case ShortcutAction.switchRemoteWindow:
        return '切换远控窗口';
      case ShortcutAction.viewMode:
        return '进入观看模式';
      case ShortcutAction.viewModeToggle:
        return '切换观看/操控模式';
      case ShortcutAction.viewModeToggleAnnotation:
        return '观看模式开关批注';
      case ShortcutAction.viewModeToggleToolbar:
        return '观看模式显示/隐藏工具栏';
      case ShortcutAction.screenshot:
        return '远程截图';
      case ShortcutAction.paste:
        return '粘贴剪贴板';
    }
  }

  /// 分组名，用于设置页分节：窗口 / 输入 / 画面 / 观看 / 其他。
  ///
  /// 按「用户想干什么」分，而不是按官方页面的顺序——同一组里的项往往互相替代，
  /// 用户找「全屏」时不会想先在几十行里扫一遍。
  String get group {
    switch (this) {
      case ShortcutAction.fullScreen:
      case ShortcutAction.bossKey:
      case ShortcutAction.smallWindowMode:
      case ShortcutAction.switchRemoteWindow:
      case ShortcutAction.quitRemote:
        return '窗口';
      case ShortcutAction.lockMouse:
      case ShortcutAction.remoteMouseMode:
      case ShortcutAction.paste:
      case ShortcutAction.ctrlAltDelete:
        return '输入';
      case ShortcutAction.screenshot:
      case ShortcutAction.muteController:
      case ShortcutAction.networkStatus:
      case ShortcutAction.previousScreen:
      case ShortcutAction.nextScreen:
        return '画面';
      case ShortcutAction.viewMode:
      case ShortcutAction.viewModeToggle:
      case ShortcutAction.viewModeToggleAnnotation:
      case ShortcutAction.viewModeToggleToolbar:
        return '观看';
      case ShortcutAction.fileTransfer:
      case ShortcutAction.floatingBall:
      case ShortcutAction.privacyMode:
      case ShortcutAction.privacyScreenSaver:
        return '其他';
    }
  }

  /// 该动作是否需要被控端配合（提示用户「需被控端支持」）。
  ///
  /// 判断标准：动作必须由被控端执行、或依赖被控端能力上报。纯控制端行为
  /// （全屏、小窗、老板键、截图在本地保存）不受对端版本影响，不提示。
  bool get needsPeer {
    switch (this) {
      case ShortcutAction.ctrlAltDelete:
      case ShortcutAction.fileTransfer:
      case ShortcutAction.muteController:
      case ShortcutAction.previousScreen:
      case ShortcutAction.nextScreen:
      case ShortcutAction.privacyMode:
      case ShortcutAction.privacyScreenSaver:
      case ShortcutAction.remoteMouseMode:
        return true;
      case ShortcutAction.bossKey:
      case ShortcutAction.floatingBall:
      case ShortcutAction.fullScreen:
      case ShortcutAction.lockMouse:
      case ShortcutAction.networkStatus:
      case ShortcutAction.quitRemote:
      case ShortcutAction.smallWindowMode:
      case ShortcutAction.switchRemoteWindow:
      case ShortcutAction.viewMode:
      case ShortcutAction.viewModeToggle:
      case ShortcutAction.viewModeToggleAnnotation:
      case ShortcutAction.viewModeToggleToolbar:
      case ShortcutAction.screenshot:
      case ShortcutAction.paste:
        return false;
    }
  }
}

/// 修饰键的固定展示顺序：meta → ctrl → alt → shift。
///
/// 顺序写死是为了让同一组合在任何键盘布局下都显示成同一个样子
/// （macOS 自己也是 ⌃⌥⇧⌘ 这套相对顺序，用户扫一眼就能认）。
const List<String> _modifierOrder = <String>['meta', 'ctrl', 'alt', 'shift'];

/// 修饰键到 macOS 风格符号的映射。
const Map<String, String> _modifierSymbols = <String, String>{
  'meta': '⌘',
  'ctrl': '⌃',
  'alt': '⌥',
  'shift': '⇧',
};

/// 部分主键的显示别名：方向键/退格画成符号，比 `ArrowLeft` 直观得多。
const Map<String, String> _keyLabels = <String, String>{
  'ArrowLeft': '←',
  'ArrowRight': '→',
  'ArrowUp': '↑',
  'ArrowDown': '↓',
  'Backspace': '⌫',
};

/// 把 keyLabel 里的平台前缀去掉，只留用户认得的那个字：
/// `KeyA` → `A`、`Digit1` → `1`。
///
/// 只在「前缀 + 单个字符」时截断：`Keypad0` / `KeyCode` 之类不能误伤，
/// 否则会显示成 `pad0`。`id` 里仍用完整 keyLabel，两者互不影响。
String _prettyKey(String key) {
  final String? alias = _keyLabels[key];
  if (alias != null) return alias;
  if (key.length == 4 && key.startsWith('Key')) return key.substring(3);
  if (key.length == 6 && key.startsWith('Digit')) return key.substring(5);
  return key;
}

/// 把字母键统一成 `KeyA` 形式。
///
/// Flutter 的 `LogicalKeyboardKey.keyLabel` 对字母键返回的是小写 `a`，
/// 而默认表/存档用的是 `KeyA`；不做这层归一，用户录一个 ⌘⇧A 拿到 `a`，
/// 会和默认的 `KeyA` 判成两个键，冲突检测也就形同虚设。
/// 只处理单字母，其余（F11 / Delete / ArrowLeft）原样返回。
String _canonicalKey(String label) {
  if (label.length != 1) return label;
  final String upper = label.toUpperCase();
  final int code = upper.codeUnitAt(0);
  if (code < 65 || code > 90) return label;
  return 'Key$upper';
}

/// 一个按键组合：修饰键集合 + 主键。主键用 Dart 的 keyLabel 字符串
/// （如 'KeyA'、'F11'、'Delete'）。
///
/// 主键不用枚举：`LogicalKeyboardKey` 有几百个值，布局相关的还会变
/// （不同键盘的 `IntlBackslash` 等），用字符串原样透传最稳，也方便落盘。
class KeyChord {
  const KeyChord({required this.key, this.modifiers = const <String>{}});

  /// 主键的 `LogicalKeyboardKey.keyLabel`（如 'KeyA' / 'F11' / 'Delete'）。
  final String key;

  /// 取值只允许 'meta' / 'ctrl' / 'alt' / 'shift'（小写）。
  final Set<String> modifiers;

  /// 按固定顺序排列后的修饰键（脏数据里的未知修饰键会被忽略）。
  List<String> get _orderedModifiers =>
      _modifierOrder.where((String m) => modifiers.contains(m)).toList();

  /// 显示文案：macOS 风格符号 ⌘⌥⌃⇧ + 主键，如 '⌘⇧A'、'F11'、'⌘⌥Delete'。
  ///
  /// 非 mac 平台也直接用这套符号：远控产品的用户大多认得，且比
  /// 'Ctrl+Shift+A' 更短，窄侧栏里不会被截断。
  String get display {
    final String prefix = _orderedModifiers
        .map((String m) => _modifierSymbols[m] ?? '')
        .join();
    final String main = _prettyKey(key);
    return '$prefix$main';
  }

  /// 未绑定/无效（主键为空）时为 true。
  bool get isEmpty => key.isEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'modifiers': _orderedModifiers,
      };

  /// 容错解析：字段缺失或类型不对时退化成空组合，绝不抛异常
  /// （旧版本/手改过的配置文件会走到这里）。
  factory KeyChord.fromJson(Map<String, dynamic> json) {
    final Object? rawKey = json['key'];
    final String key = rawKey is String ? rawKey : '';
    final Set<String> mods = <String>{};
    final Object? rawMods = json['modifiers'];
    if (rawMods is List) {
      for (final Object? m in rawMods) {
        if (m is String && _modifierOrder.contains(m.toLowerCase())) {
          mods.add(m.toLowerCase());
        }
      }
    }
    return KeyChord(key: key, modifiers: mods);
  }

  /// 规范化签名，用于冲突比较（与 display 无关）。
  ///
  /// 修饰键按字母序拼接（alt < ctrl < meta < shift），所以 `{meta, alt}` 与
  /// `{alt, meta}` 得到同一个 id；显示顺序不同不影响「是不是同一个键」。
  /// 无修饰键时只有主键本身，避免出现 `+F11` 这种怪串。
  String get id {
    final List<String> mods = _orderedModifiers.toList()..sort();
    if (mods.isEmpty) return key;
    return '${mods.join('+')}+$key';
  }

  @override
  bool operator ==(Object other) => other is KeyChord && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'KeyChord($id)';
}

/// 录制结果。
enum RecordVerdict {
  /// 可用。
  ok,

  /// 按了 Backspace/Delete 且无修饰键 → 删除绑定。
  clear,

  /// 只按了修饰键 → 忽略，不提示错误（用户还在按组合键的中间态）。
  modifierOnly,

  /// 非法键（系统保留 / 单独的方向键等）。
  invalid;

  /// 提示文案。其余状态为空串——`modifierOnly` 是正常中间态，报错反而打断用户。
  String get message => this == RecordVerdict.invalid ? '该按键不可设置' : '';
}

/// 一次录制的结果。[chord] 在 `ok` 时有值，`clear`/`invalid` 时为 null。
class RecordOutcome {
  const RecordOutcome(this.verdict, [this.chord]);

  final RecordVerdict verdict;
  final KeyChord? chord;
}

/// 快捷键配置：默认值 + 用户覆盖。
///
/// 覆盖表里「值为 null」表示用户主动删除了绑定，与「没改过、跟随默认」
/// 是两种状态，必须分开存——否则用户删掉 `paste` 的 ⌘V 后一重启又回来了。
class ShortcutMap {
  ShortcutMap({Map<ShortcutAction, KeyChord?>? overrides}) {
    if (overrides != null) {
      _overrides.addAll(overrides);
    }
  }

  /// 出厂默认（官方默认值）。
  ///
  /// 没进这张表的动作就是「默认不绑定」：官方这些项要么是开关键
  /// （悬浮球/老板键），要么有平台差异（锁鼠标/鼠标模式），硬给一个
  /// 组合反而会和用户已有习惯冲突。
  static const Map<ShortcutAction, KeyChord> _defaults =
      <ShortcutAction, KeyChord>{
    ShortcutAction.fullScreen: KeyChord(key: 'F11'),
    ShortcutAction.quitRemote: KeyChord(
      key: 'KeyQ',
      modifiers: <String>{'meta', 'shift'},
    ),
    // 注意：这个动作是「替用户按 Ctrl+Alt+Delete」，绑定本身用 ⌘⌥Delete，
    // 系统安全键不可捕获，不能把它当成绑定值。
    ShortcutAction.ctrlAltDelete: KeyChord(
      key: 'Delete',
      modifiers: <String>{'meta', 'alt'},
    ),
    ShortcutAction.muteController: KeyChord(
      key: 'KeyM',
      modifiers: <String>{'meta', 'shift'},
    ),
    ShortcutAction.networkStatus: KeyChord(
      key: 'KeyN',
      modifiers: <String>{'meta', 'shift'},
    ),
    ShortcutAction.previousScreen: KeyChord(
      key: 'ArrowLeft',
      modifiers: <String>{'meta', 'shift'},
    ),
    ShortcutAction.nextScreen: KeyChord(
      key: 'ArrowRight',
      modifiers: <String>{'meta', 'shift'},
    ),
    ShortcutAction.viewModeToggle: KeyChord(
      key: 'KeyV',
      modifiers: <String>{'meta', 'shift'},
    ),
    ShortcutAction.viewModeToggleAnnotation: KeyChord(
      key: 'KeyA',
      modifiers: <String>{'meta', 'shift'},
    ),
    ShortcutAction.viewModeToggleToolbar: KeyChord(
      key: 'KeyT',
      modifiers: <String>{'meta', 'shift'},
    ),
    ShortcutAction.smallWindowMode: KeyChord(
      key: 'KeyW',
      modifiers: <String>{'meta', 'shift'},
    ),
    ShortcutAction.paste: KeyChord(key: 'KeyV', modifiers: <String>{'meta'}),
    ShortcutAction.screenshot: KeyChord(
      key: 'KeyS',
      modifiers: <String>{'meta', 'shift'},
    ),
  };

  /// 用户覆盖：key 存在即「已定制」，value 为 null 表示已删除绑定。
  final Map<ShortcutAction, KeyChord?> _overrides =
      <ShortcutAction, KeyChord?>{};

  /// 出厂默认表（只含默认绑定了的动作，未绑定的动作不在此表中）。
  static Map<ShortcutAction, KeyChord> get defaults => _defaults;

  /// 当前生效的组合；返回 null 表示该项未绑定（用户按 ⌫ 删掉了）。
  KeyChord? chordOf(ShortcutAction action) {
    if (_overrides.containsKey(action)) return _overrides[action];
    return _defaults[action];
  }

  /// 该组合被谁占用（不含自己）；无冲突返回 null。
  ShortcutAction? conflictOf(ShortcutAction action, KeyChord chord) {
    if (chord.isEmpty) return null;
    final String target = chord.id;
    for (final ShortcutAction other in ShortcutAction.values) {
      if (other == action) continue;
      if (chordOf(other)?.id == target) return other;
    }
    return null;
  }

  /// 设置。若与别的动作冲突，**不写入**并返回占用者。
  ///
  /// 不覆盖、不交换：录制界面只提示「快捷键冲突」，让用户自己决定要不要
  /// 先清掉对方；静默抢占会让用户丢了另一个功能的键还不知道。
  ShortcutAction? set(ShortcutAction action, KeyChord chord) {
    final ShortcutAction? owner = conflictOf(action, chord);
    if (owner != null) return owner;
    _overrides[action] = chord;
    return null;
  }

  /// 删除绑定（⌫）。
  void clear(ShortcutAction action) {
    _overrides[action] = null;
  }

  /// 恢复单项默认。
  void reset(ShortcutAction action) {
    _overrides.remove(action);
  }

  /// 恢复全部。
  void resetAll() {
    _overrides.clear();
  }

  /// 当前值是否等于出厂默认（未绑定的动作，只要用户没改过也算默认）。
  bool isDefault(ShortcutAction action) {
    final KeyChord? now = chordOf(action);
    final KeyChord? factory = _defaults[action];
    if (now == null || factory == null) return now == null && factory == null;
    return now.id == factory.id;
  }

  bool get hasCustom => ShortcutAction.values.any((ShortcutAction a) => !isDefault(a));

  /// 反查：哪个动作绑了这个组合（键盘事件分发用）。
  ///
  /// 线性扫 22 项，一次按键几十纳秒，不值得为它维护索引表
  /// （索引还要在 set/clear/reset 时同步，容易漏）。
  ShortcutAction? actionFor(KeyChord chord) {
    if (chord.isEmpty) return null;
    final String target = chord.id;
    for (final ShortcutAction action in ShortcutAction.values) {
      if (chordOf(action)?.id == target) return action;
    }
    return null;
  }

  /// 只存用户覆盖（含「已删除」的 null 项），默认值不进配置文件——
  /// 以后调默认键位时老用户能跟着更新。
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> bindings = <String, dynamic>{};
    _overrides.forEach((ShortcutAction action, KeyChord? chord) {
      bindings[action.name] = chord?.toJson();
    });
    return <String, dynamic>{
      'version': 1,
      'bindings': bindings,
    };
  }

  /// 容错解析：null / 字段缺失 / 未知动作 / 值类型不对，一律跳过。
  factory ShortcutMap.fromJson(Map<String, dynamic>? json) {
    if (json == null) return ShortcutMap();
    final Object? rawBindings = json['bindings'];
    if (rawBindings is! Map) return ShortcutMap();

    final Map<ShortcutAction, KeyChord?> overrides =
        <ShortcutAction, KeyChord?>{};
    final Set<String> takenIds = <String>{};
    rawBindings.forEach((dynamic rawAction, dynamic rawChord) {
      final ShortcutAction? action = _actionByName(rawAction);
      if (action == null) return;
      if (rawChord == null) {
        // 用户删过绑定：如实还原成「未绑定」
        overrides[action] = null;
        return;
      }
      if (rawChord is! Map) return;
      final Map<String, dynamic> obj = <String, dynamic>{};
      rawChord.forEach((dynamic k, dynamic v) {
        if (k is String) obj[k] = v;
      });
      final KeyChord chord = KeyChord.fromJson(obj);
      // 空主键 = 脏数据，跳过让它回落默认
      if (chord.isEmpty) return;
      // 手改过的配置可能把同一个组合给两个动作，先到先得，避免反查歧义
      if (!takenIds.add(chord.id)) return;
      overrides[action] = chord;
    });
    return ShortcutMap(overrides: overrides);
  }

  /// 从一次按键事件解析（主控把 LogicalKeyboardKey 的 keyLabel 与当前
  /// modifiers 传进来）。
  ///
  /// 注意顺序：`isModifierOnly` 优先于其它判断——用户按下 ⌘ 的瞬间 keyLabel
  /// 是 'MetaLeft'，此时不该报「不可设置」也不该被当成有效组合。
  static RecordOutcome record({
    required String keyLabel,
    required Set<String> modifiers,
    required bool isModifierOnly,
  }) {
    if (isModifierOnly) {
      return const RecordOutcome(RecordVerdict.modifierOnly);
    }
    final Set<String> mods = <String>{
      for (final String m in modifiers)
        if (_modifierOrder.contains(m.toLowerCase())) m.toLowerCase(),
    };
    if (keyLabel.isEmpty) {
      return const RecordOutcome(RecordVerdict.invalid);
    }
    // 先归一字母键再建 chord：否则 'a' 与 'KeyA' 会被当成两个键
    final String key = _canonicalKey(keyLabel);
    final KeyChord chord = KeyChord(key: key, modifiers: mods);
    // 无修饰键的 ⌫/Delete 才是「删除」；⌘⌥Delete 是正常组合（ctrlAltDelete）
    if (mods.isEmpty && (key == 'Backspace' || key == 'Delete')) {
      return const RecordOutcome(RecordVerdict.clear);
    }
    if (ReservedChords.isReserved(chord)) {
      return const RecordOutcome(RecordVerdict.invalid);
    }
    return RecordOutcome(RecordVerdict.ok, chord);
  }

  static ShortcutAction? _actionByName(dynamic raw) {
    if (raw is! String) return null;
    for (final ShortcutAction action in ShortcutAction.values) {
      if (action.name == raw) return action;
    }
    return null;
  }
}

/// 系统保留、不允许绑定的组合（录制时直接判 invalid）。
///
/// 这些组合按下后会被操作系统先吃掉：能捕获到也发不出去，绑上了等于
/// 用户以为设成功了、实际永远不触发，比拒绝更糟。
class ReservedChords {
  ReservedChords._();

  /// 系统保留组合：⌘Q（macOS 退出）、⌘Tab（系统切窗）、⌘Space（Spotlight）、
  /// Alt+F4（Windows 关窗）、Ctrl+Alt+Delete（系统安全键，不可捕获）。
  ///
  /// 精确匹配修饰键集合：⌘⇧Q 是本工程的 `quitRemote` 默认值、⌘⌥Delete 是
  /// `ctrlAltDelete` 的默认值，多按一个修饰键就是另一个组合，不能误判。
  static bool isReserved(KeyChord chord) {
    final Set<String> mods = chord.modifiers
        .where((String m) => _modifierOrder.contains(m))
        .toSet();
    bool exact(Set<String> expected) =>
        mods.length == expected.length && mods.containsAll(expected);

    // 主键先归一（KeyQ → Q），这样 'KeyQ' 与 'Q' 两种写法都能拦住
    switch (_prettyKey(chord.key)) {
      case 'Q':
        return exact(<String>{'meta'});
      case 'Tab':
        return exact(<String>{'meta'});
      case 'Space':
        return exact(<String>{'meta'});
      case 'F4':
        return exact(<String>{'alt'});
      case 'Delete':
        return exact(<String>{'ctrl', 'alt'});
      default:
        return false;
    }
  }
}
