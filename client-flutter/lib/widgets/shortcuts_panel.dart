import 'dart:convert' show jsonEncode;

import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

import '../core/shortcuts.dart';
import '../core/theme.dart';

/// 是否是「修饰键本身」。
///
/// 不用 `LogicalKeyboardKey.isModifierKey`：那是较新版本才有的 getter，
/// 这里显式列出来，既能编译在旧 SDK 上，也让「哪些算修饰键」一目了然
/// ——必须和 `shortcuts.dart` 里认的 meta/ctrl/alt/shift 完全一致。
bool _isModifierOnly(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.metaLeft ||
    key == LogicalKeyboardKey.metaRight ||
    key == LogicalKeyboardKey.controlLeft ||
    key == LogicalKeyboardKey.controlRight ||
    key == LogicalKeyboardKey.altLeft ||
    key == LogicalKeyboardKey.altRight ||
    key == LogicalKeyboardKey.shiftLeft ||
    key == LogicalKeyboardKey.shiftRight;

/// 快捷键配置面板（官方 B6.1，22 项）。
///
/// 交互照官方：点某一项进入「录制」态，直接按下组合键即可设置；
/// 按 ⌫ 删除绑定；冲突当场提示「快捷键冲突」；非法键提示「该按键不可设置」。
class ShortcutsPanel extends StatefulWidget {
  const ShortcutsPanel({required this.map, required this.onChanged, super.key});

  final ShortcutMap map;

  /// 每次改完立刻回调，调用方负责落盘。
  final ValueChanged<ShortcutMap> onChanged;

  @override
  State<ShortcutsPanel> createState() => _ShortcutsPanelState();
}

class _ShortcutsPanelState extends State<ShortcutsPanel> {
  late final ShortcutMap _map = widget.map;

  /// 正在录制的那一项；null 表示没有在录制。
  ShortcutAction? _recording;

  /// 冲突/非法提示。放在面板顶部而不是 SnackBar：SnackBar 会盖住底部的行。
  String? _error;

  final FocusNode _focus = FocusNode(debugLabel: 'shortcut-recorder');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _startRecording(ShortcutAction action) {
    setState(() {
      _recording = action;
      _error = null;
    });
    // 面板本身可能没焦点，录制的第一下按键会丢
    _focus.requestFocus();
  }

  void _handleKey(KeyEvent event) {
    final ShortcutAction? action = _recording;
    if (action == null || event is! KeyDownEvent) return;

    // Esc 退出录制（不作为可绑定的键）
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        _recording = null;
        _error = null;
      });
      return;
    }

    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final Set<String> modifiers = <String>{};
    if (keyboard.isMetaPressed) modifiers.add('meta');
    if (keyboard.isControlPressed) modifiers.add('ctrl');
    if (keyboard.isAltPressed) modifiers.add('alt');
    if (keyboard.isShiftPressed) modifiers.add('shift');

    final RecordOutcome outcome = ShortcutMap.record(
      keyLabel: event.logicalKey.keyLabel,
      modifiers: modifiers,
      isModifierOnly: _isModifierOnly(event.logicalKey),
    );

    switch (outcome.verdict) {
      case RecordVerdict.modifierOnly:
        // 只按了修饰键：不提示、不结束录制，等用户按完整组合
        return;
      case RecordVerdict.clear:
        _map.clear(action);
        _commit('已删除「${action.label}」的快捷键');
      case RecordVerdict.ok:
        final KeyChord? chord = outcome.chord;
        if (chord == null) return;
        final ShortcutAction? occupied = _map.conflictOf(action, chord);
        if (occupied != null) {
          setState(() => _error = '快捷键冲突：「${chord.display}」已用于「${occupied.label}」');
          return;
        }
        _map.set(action, chord);
        _commit(null);
      case RecordVerdict.invalid:
        setState(() => _error = outcome.verdict.message.isEmpty
            ? '该按键不可设置'
            : outcome.verdict.message);
    }
  }

  /// 收尾一次改动：退出录制态、清空错误、把新表交给调用方落盘。
  void _commit(String? message) {
    setState(() {
      _recording = null;
      _error = null;
    });
    widget.onChanged(_map);
    if (message != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // 按 group 归并，保持 enum 声明顺序（官方表也是按功能排的）
    final Map<String, List<ShortcutAction>> byGroup = <String, List<ShortcutAction>>{};
    for (final ShortcutAction action in ShortcutAction.values) {
      byGroup.putIfAbsent(action.group, () => <ShortcutAction>[]).add(action);
    }

    return KeyboardListener(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _header(),
            if (_error != null) _errorBanner(),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.only(bottom: AppSpace.lg),
                children: <Widget>[
                  for (final MapEntry<String, List<ShortcutAction>> entry in byGroup.entries)
                    ...<Widget>[
                      _groupTitle(entry.key),
                      for (final ShortcutAction action in entry.value) _row(action),
                    ],
                ],
              ),
            ),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.md, AppSpace.sm),
      child: Row(
        children: <Widget>[
          const Expanded(
            child: Text(
              '快捷键',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.text),
            ),
          ),
          TextButton(
            onPressed: _map.hasCustom
                ? () {
                    _map.resetAll();
                    widget.onChanged(_map);
                    setState(() => _error = null);
                  }
                : null,
            child: const Text('全部恢复默认'),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.error_outline, size: 14, color: AppColors.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 11.5, color: AppColors.danger, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupTitle(String group) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.lg, 4),
      child: Text(
        group,
        style: const TextStyle(
          fontSize: 11,
          color: AppColors.faint,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _row(ShortcutAction action) {
    final bool recording = _recording == action;
    final KeyChord? chord = _map.chordOf(action);
    return InkWell(
      onTap: () => _startRecording(action),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: 9),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                action.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: AppColors.text),
              ),
            ),
            if (action.needsPeer)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Tooltip(
                  message: '需要被控端配合',
                  child: Icon(Icons.computer, size: 13, color: AppColors.faint),
                ),
              ),
            if (recording)
              _keyBox('按下按键…', highlight: true)
            else if (chord == null)
              const Text('未设置', style: TextStyle(fontSize: 11.5, color: AppColors.faint))
            else
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _keyBox(chord.display),
                  const SizedBox(width: 2),
                  IconButton(
                    tooltip: '删除这个绑定',
                    onPressed: () {
                      _map.clear(action);
                      widget.onChanged(_map);
                      setState(() => _error = null);
                    },
                    icon: const Icon(Icons.backspace_outlined, size: 14, color: AppColors.faint),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _keyBox(String text, {bool highlight = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: highlight ? AppColors.accentDim : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: highlight ? AppColors.accent : AppColors.border,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          color: highlight ? AppColors.accent : AppColors.text,
          fontWeight: FontWeight.w500,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  Widget _footer() {
    final ShortcutAction? action = _recording;
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.md),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              action == null
                  ? '点任意一项开始录制；录制时按 ⌫ 删除绑定，Esc 放弃'
                  : '正在录制「${action.label}」：按下组合键（⌫ 删除，Esc 放弃）',
              style: TextStyle(
                fontSize: 11,
                color: action == null ? AppColors.muted : AppColors.accent,
                height: 1.4,
              ),
            ),
          ),
          if (action != null)
            TextButton(
              onPressed: () => setState(() {
                _recording = null;
                _error = null;
              }),
              child: const Text('取消'),
            ),
        ],
      ),
    );
  }
}

/// 打开快捷键面板。返回时调用方拿到的是「已经通过 onChanged 落过盘的」新表。
Future<void> showShortcutsPanel(
  BuildContext context, {
  required ShortcutMap map,
  required ValueChanged<ShortcutMap> onChanged,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) => ShortcutsPanel(map: map, onChanged: onChanged),
  );
}

/// 把当前表序列化成可落盘的字符串。
String encodeShortcuts(ShortcutMap map) => jsonEncode(map.toJson());
