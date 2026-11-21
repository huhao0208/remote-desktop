/// 跨平台键位映射（协议 v3 §4）：只在控制端做，只在跨平台时生效。
///
/// 为什么映射放控制端：Agent 侧只认 pyautogui 键名，它不知道（也不该知道）
/// 对面是 macOS 还是 Windows。两边都维护映射表必然有一处对不上，
/// 出问题时也分不清是谁的锅。
///
/// 词表红线：协议里的修饰键只有 `ctrl` / `shift` / `alt` / `win` 四个
/// （见 `input_events.dart` 的 `modifierName`），macOS 的 ⌘ 在协议里**就叫
/// `win`**。映射只能在这四个词之间换——一旦产出 `cmd`/`command`/`option`
/// 这种「更自然」的新词，Agent 的 `_norm_key` 认不出来，那个键就静默失效。
library;

/// macOS 控制端按 ⌘ 时，Windows 被控端该收到哪个键。
///
/// 对齐官方 `Setting.Keyboard.WindowsMapping.*`：默认 Win（贴近「⌘ 就是
/// 系统键」的直觉），可配成 Ctrl（照顾按 Windows 习惯用 Ctrl+C 的用户）。
enum CmdTarget { win, ctrl }

extension CmdTargetInfo on CmdTarget {
  /// 设置页下拉框里的文案。
  String get label {
    switch (this) {
      case CmdTarget.win:
        return 'Win 键';
      case CmdTarget.ctrl:
        return 'Ctrl 键';
    }
  }
}

/// 键位映射配置。不可变值，与 `MouseSettings` 同一套写法。
class KeyMappingConfig {
  const KeyMappingConfig({
    this.cmdAs = CmdTarget.win,
    this.deleteAsBackspace = true,
  });

  /// ⌘ → Win（默认）还是 Ctrl。
  final CmdTarget cmdAs;

  /// macOS 的 Delete（⌫，退格）映射为 Backspace。
  ///
  /// macOS 键盘上标着 Delete 的那颗键实际是退格，Windows 侧对应 `backspace`；
  /// 若原样发 `delete`，远端会变成「向后删除」，用户打字时一路吃字。
  final bool deleteAsBackspace;

  KeyMappingConfig copyWith({CmdTarget? cmdAs, bool? deleteAsBackspace}) =>
      KeyMappingConfig(
        cmdAs: cmdAs ?? this.cmdAs,
        deleteAsBackspace: deleteAsBackspace ?? this.deleteAsBackspace,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'cmdAs': cmdAs.name,
    'deleteAsBackspace': deleteAsBackspace,
  };

  /// 容错解析：缺字段/类型错退默认（默认值就是官方默认，最安全）。
  factory KeyMappingConfig.fromJson(Map<String, dynamic> json) {
    final Object? rawCmd = json['cmdAs'];
    final CmdTarget cmdAs = rawCmd is String && rawCmd.toLowerCase() == 'ctrl'
        ? CmdTarget.ctrl
        : CmdTarget.win;
    final Object? rawDelete = json['deleteAsBackspace'];
    return KeyMappingConfig(
      cmdAs: cmdAs,
      deleteAsBackspace: rawDelete is bool ? rawDelete : true,
    );
  }

  @override
  String toString() =>
      'KeyMappingConfig(cmdAs: ${cmdAs.name}, deleteAsBackspace: $deleteAsBackspace)';
}

/// 键名归一化 + 跨平台映射。
class KeyMapper {
  KeyMapper._();

  /// 归一化后的平台名。
  static const String macos = 'macos';
  static const String windows = 'windows';
  static const String linux = 'linux';

  /// 平台名归一化：`macOS`/`darwin`/`mac` → `macos`，`win32`/`Windows` → `windows`，
  /// 其余（含空串、Android）→ `linux`。
  ///
  /// 之所以要归一：`Platform.operatingSystem` 给 `macos`，`Platform.platform`
  /// 给 `macos-14.x-arm64`，Agent 上报的可能是 `darwin`/`win32`，直接比较字符串
  /// 迟早漏一种写法，而漏掉的后果是「映射静默不生效」。
  static String normalizeOs(String raw) {
    final String os = raw.trim().toLowerCase();
    // 先判 mac：`darwin` 里也含 `win`，先判 windows 会把 Mac 认成 Windows
    if (os.startsWith('mac') || os == 'darwin' || os == 'osx') return macos;
    if (os.startsWith('win') || os.contains('windows')) return windows;
    return linux;
  }

  /// 是否跨平台（只有 macOS ↔ Windows 需要映射）。
  ///
  /// Linux 不在表内：X11/Wayland 的键名本来就按 evdev 传，和协议词表一致，
  /// 硬加一层映射反而多一次出错机会（协议 §4「Linux 任一端 → 直通」）。
  static bool isCrossPlatform(String localOs, String remoteOs) {
    final String local = normalizeOs(localOs);
    final String remote = normalizeOs(remoteOs);
    return (local == macos && remote == windows) ||
        (local == windows && remote == macos);
  }

  /// 把协议词表里的键名映射成被控端平台的键名。
  ///
  /// [key] 用 `RemoteKeyMapper` 同一套词表（`ctrl`/`shift`/`alt`/`win`/
  /// `enter`/`delete`/`backspace`/`a`…），传入前应已由它转成小写协议名。
  ///
  /// 同平台、Linux 任一端、以及表外的普通键一律原样返回——**不做多余的
  /// 小写化**，否则 `KeyA` 这类上层写法会被悄悄改成 `keya`，反而更难排查。
  static String mapKey(
    String key, {
    required String localOs,
    required String remoteOs,
    required KeyMappingConfig config,
  }) {
    final String local = normalizeOs(localOs);
    final String remote = normalizeOs(remoteOs);
    if (!isCrossPlatform(local, remote)) return key;

    // 比较用小写副本，返回用协议词表的小写规范名
    final String k = key.toLowerCase();

    if (local == macos) {
      // macOS 控制端 → Windows 被控端
      switch (k) {
        case 'win':
          // ⌘ 在协议里叫 win；到 Windows 上要么是 Win 键要么是 Ctrl 键
          return config.cmdAs == CmdTarget.ctrl ? 'ctrl' : 'win';
        case 'delete':
          return config.deleteAsBackspace ? 'backspace' : 'delete';
        case 'alt':
          // ⌥ 在协议里就叫 alt，Windows 侧同样是 alt，这里显式写出来
          // 是为了让「表里就这几条」一目了然，不是漏改
          return 'alt';
        default:
          return key;
      }
    }

    // Windows 控制端 → macOS 被控端
    switch (k) {
      case 'win':
        // 协议词表里 macOS 的 ⌘ **仍然叫 win**，不要发明 cmd/command
        return 'win';
      case 'alt':
        // Windows 的 Alt 到 macOS 是 ⌥，协议词表里仍叫 alt
        return 'alt';
      default:
        return key;
    }
  }
}

/// 给设置页用的一句话说明（口径对齐官方 `Setting.Keyboard.WindowsMapping`）。
///
/// 同平台时也要返回非空文案：那一栏是「是否生效」的唯一提示，
/// 留空会让用户以为功能坏了。
String describeMapping(
  String localOs,
  String remoteOs,
  KeyMappingConfig config,
) {
  final String local = KeyMapper.normalizeOs(localOs);
  final String remote = KeyMapper.normalizeOs(remoteOs);
  if (!KeyMapper.isCrossPlatform(local, remote)) {
    return '键位原样发送，不做映射（仅 macOS ↔ Windows 之间生效）';
  }
  if (local == KeyMapper.macos) {
    final String cmd = config.cmdAs == CmdTarget.ctrl ? 'Ctrl' : 'Win';
    final String del = config.deleteAsBackspace ? '，Delete → Backspace' : '';
    return '⌘ → $cmd，⌥ → Alt$del';
  }
  return 'Win → ⌘，Alt → ⌥';
}
