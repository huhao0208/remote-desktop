import 'package:flutter/services.dart';

/// 输入事件构造器。字段名严格对齐 `srv2/control.html` 与
/// `docs/media-protocol.md` §6：`{p:"input", t:..., x, y, ...}`，x/y 归一化 0..1。
class InputEvent {
  InputEvent._();

  static double _norm(num v) => v.toDouble().clamp(0.0, 1.0);

  static Map<String, dynamic> move(num x, num y) =>
      <String, dynamic>{'p': 'input', 't': 'move', 'x': _norm(x), 'y': _norm(y)};

  static Map<String, dynamic> click(num x, num y, {String btn = 'left'}) =>
      <String, dynamic>{'p': 'input', 't': 'click', 'btn': btn, 'x': _norm(x), 'y': _norm(y)};

  static Map<String, dynamic> scroll(num dy) =>
      <String, dynamic>{'p': 'input', 't': 'scroll', 'dy': dy.toInt()};

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