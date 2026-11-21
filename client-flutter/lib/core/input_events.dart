import 'package:flutter/services.dart';

/// 输入事件构造器。字段名严格对齐 `srv2/control.html` 与
/// `docs/media-protocol.md` §6：`{p:"input", t:..., x, y, ...}`，x/y 归一化 0..1。
class InputEvent {
  InputEvent._();

  static double _norm(num v) => v.toDouble().clamp(0.0, 1.0);

  static Map<String, dynamic> move(num x, num y) =>
      <String, dynamic>{'p': 'input', 't': 'move', 'x': _norm(x), 'y': _norm(y)};

  /// 相对位移（协议 v3 §3，只用于「使用主控端鼠标」与游戏模式）。
  ///
  /// 与 [move] 的区别是语义：绝对坐标要求两端坐标系一致，一个网络抖动就会「跳」；
  /// 相对位移由被控端在本地累加并 warp，**不吃系统指针加速**，所以手感线性可控。
  /// [dx]/[dy] 是屏幕宽/高的归一化比例（0.001 = 0.1%），**不裁到 0..1**——负值合法。
  static Map<String, dynamic> moveRel(num dx, num dy) => <String, dynamic>{
        'p': 'input',
        't': 'moverel',
        'dx': dx.toDouble(),
        'dy': dy.toDouble(),
      };

  /// 被控端系统光标可见性（协议 v3 §3）。
  ///
  /// 切回「使用被控端鼠标」时**必须**发 `visible:true`，否则远端光标一直藏着，
  /// 用户会以为鼠标坏了。
  static Map<String, dynamic> cursor(bool visible) =>
      <String, dynamic>{'p': 'cursor', 'visible': visible};

  static Map<String, dynamic> click(num x, num y, {String btn = 'left'}) =>
      <String, dynamic>{'p': 'input', 't': 'click', 'btn': btn, 'x': _norm(x), 'y': _norm(y)};

  /// 滚轮。[mods] 是**当前真实按住的修饰键**（v2 §4）：Agent 侧看到 mods 会
  /// 临时按住再滚，`Ctrl+滚轮` 才能触达远端缩放；空列表则不附加字段。
  static Map<String, dynamic> scroll(num dy, {List<String> mods = const <String>[]}) =>
      <String, dynamic>{
        'p': 'input',
        't': 'scroll',
        'dy': dy.toInt(),
        if (mods.isNotEmpty) 'mods': mods,
      };

  /// 按下并抬起（含组合键主键）。
  static Map<String, dynamic> press(String key) =>
      <String, dynamic>{'p': 'input', 't': 'press', 'k': key};

  /// 修饰键按住 / 松开，用于「按住 Shift 点选」「按住 Ctrl 滚轮缩放」。
  static Map<String, dynamic> keyDown(String key) =>
      <String, dynamic>{'p': 'input', 't': 'keydown', 'k': key};

  static Map<String, dynamic> keyUp(String key) =>
      <String, dynamic>{'p': 'input', 't': 'keyup', 'k': key};

  /// 字符直达（IME / 软键盘输入）。
  static Map<String, dynamic> text(String value) =>
      <String, dynamic>{'p': 'input', 't': 'text', 'v': value};

  /// 预置组合键（协议里的 `combo` 形态，如 `["ctrl","c"]`）。
  static Map<String, dynamic> combo(List<String> combo) =>
      <String, dynamic>{'p': 'input', 't': 'key', 'combo': combo};

  static Map<String, dynamic> streamConfig({
    required int width,
    required int quality,
    required int fps,
    required int bitrate,
  }) =>
      <String, dynamic>{
        'p': 'stream.config',
        'width': width,
        'quality': quality,
        'fps': fps,
        'bitrate': bitrate,
      };

  static Map<String, dynamic> shutdown({int delay = 30}) =>
      <String, dynamic>{'p': 'shutdown', 'delay': delay};

  static Map<String, dynamic> cancelShutdown() =>
      <String, dynamic>{'p': 'shutdown', 'cancel': true};

  /// 剪贴板上行（协议 v2 §2）：把本机文本写进被控端剪贴板。
  ///
  /// 与 [text] 的区别：[text] 是「像打字一样输入」，本构造器只改远端剪贴板，
  /// 由用户自己在远端按粘贴。双向同步靠它。
  static Map<String, dynamic> clipUp(String value) =>
      <String, dynamic>{'p': 'clip', 'dir': 'up', 'text': value};

  /// 剪贴板同步开关。**Agent 侧默认关闭**，必须显式打开才会推 `dir:"down"`。
  static Map<String, dynamic> clipSync(bool enable) =>
      <String, dynamic>{'p': 'clip.sync', 'enable': enable};

  /// 只看不控：进观看/批注态时告知被控端。
  ///
  /// Agent 收到 `enable:true` 会 `release_all()` 清掉按住的修饰键——本端之后
  /// 不再发 input，若不在切换瞬间补这一下，远端会一直卡着 Shift/Alt。
  static Map<String, dynamic> viewOnly(bool enable) =>
      <String, dynamic>{'p': 'view.only', 'enable': enable};
}

/// Flutter 键位 → 协议键名（对齐 control.html 的 MODKEYS / KEYMAP）。
class RemoteKeyMapper {
  RemoteKeyMapper._();

  static const Map<String, String> _byLabel = <String, String>{
    'Enter': 'enter',
    'Backspace': 'backspace',
    'Tab': 'tab',
    'Escape': 'esc',
    'Delete': 'delete',
    'Insert': 'insert',
    'Home': 'home',
    'End': 'end',
    'Page Up': 'pageup',
    'Page Down': 'pagedown',
    'Arrow Up': 'up',
    'Arrow Down': 'down',
    'Arrow Left': 'left',
    'Arrow Right': 'right',
    ' ': 'space',
    'Caps Lock': 'capslock',
    'Print Screen': 'printscreen',
    'Scroll Lock': 'scrolllock',
    'Pause': 'pause',
    'Num Lock': 'numlock',
  };

  /// 修饰键名，非修饰键返回 null。
  static String? modifierName(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.controlLeft || key == LogicalKeyboardKey.controlRight) return 'ctrl';
    if (key == LogicalKeyboardKey.shiftLeft || key == LogicalKeyboardKey.shiftRight) return 'shift';
    if (key == LogicalKeyboardKey.altLeft || key == LogicalKeyboardKey.altRight) return 'alt';
    if (key == LogicalKeyboardKey.metaLeft || key == LogicalKeyboardKey.metaRight) return 'win';
    return null;
  }

  static bool isModifier(LogicalKeyboardKey key) => modifierName(key) != null;

  /// 普通按键 → 协议键名；无法映射（纯字符键）返回 null，走 `text` 事件。
  static String? keyName(LogicalKeyboardKey key) {
    final mapped = _byLabel[key.keyLabel];
    if (mapped != null) return mapped;
    final label = key.keyLabel;
    if (label.length == 1) return label.toLowerCase();
    return null;
  }
}