import 'package:material_ui/material_ui.dart';

import '../core/key_mapping.dart';
import '../core/theme.dart';
import 'ui_kit.dart';

/// 外设面板：键位映射（协议 v3 之外，纯客户端约定）。
///
/// 两项就够用——⌘ 键当成 Win 还是 Ctrl、Delete 是否当 Backspace——
/// 再多选项用户记不住。底部常驻一行 `describeMapping` 的结果，
/// 把「当前到底按哪个规则发」说清楚。
///
/// **不自带背景**：宽 320，放进 `GlassPanel` 或 `videoChrome` 弹出层。
/// 同平台直连时键位本来就直通，整组置灰避免用户白配一遍。
class PeripheralPanel extends StatelessWidget {
  const PeripheralPanel({
    super.key,
    required this.config,
    required this.localOs,
    required this.remoteOs,
    required this.onChanged,
  });

  final KeyMappingConfig config;
  final String localOs;
  final String remoteOs;
  final ValueChanged<KeyMappingConfig> onChanged;

  /// 大小写不同（`macOS` / `macos`）不该被当成跨平台，统一小写比。
  bool get _sameOs => localOs.toLowerCase() == remoteOs.toLowerCase();

  @override
  Widget build(BuildContext context) {
    final bool enabled = !_sameOs;
    return SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _header(enabled),
          _cmdRow(enabled),
          _deleteRow(enabled),
          _footer(),
        ],
      ),
    );
  }

  Widget _header(bool enabled) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: <Widget>[
          const Text(
            '外设',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.videoText),
          ),
          const SizedBox(width: AppSpace.sm),
          Text(
            enabled ? '${localOs.toUpperCase()} → ${remoteOs.toUpperCase()}' : '同平台',
            style: const TextStyle(fontSize: 10, color: AppColors.videoMuted, letterSpacing: 0.2),
          ),
        ],
      ),
    );
  }

  Widget _cmdRow(bool enabled) {
    final Color fg = enabled ? AppColors.videoText : AppColors.videoMuted.withValues(alpha: 0.45);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('⌘ 键映射为', style: TextStyle(fontSize: 12.5, color: fg)),
                const SizedBox(height: 1),
                Text(
                  enabled ? '本机 ⌘ 组合键发到被控端时按哪个键算' : '键位直通，无需映射',
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.3,
                    color: enabled ? AppColors.videoMuted : fg,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _segment('Win 键', CmdTarget.win, enabled),
              const SizedBox(width: 4),
              _segment('Ctrl 键', CmdTarget.ctrl, enabled),
            ],
          ),
        ],
      ),
    );
  }

  Widget _segment(String text, CmdTarget value, bool enabled) {
    final bool on = config.cmdAs == value;
    final Color fg = !enabled
        ? AppColors.videoMuted.withValues(alpha: 0.45)
        : (on ? Colors.white : AppColors.videoMuted);
    return InkWell(
      onTap: enabled ? () => onChanged(config.copyWith(cmdAs: value)) : null,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on
              ? (enabled ? AppColors.accent : AppColors.accent.withValues(alpha: 0.3))
              : AppColors.videoBg,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: on
                ? (enabled ? AppColors.accent : AppColors.accent.withValues(alpha: 0.3))
                : AppColors.videoChromeBorder,
          ),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 11, color: fg, fontWeight: on ? FontWeight.w500 : FontWeight.w400),
        ),
      ),
    );
  }

  Widget _deleteRow(bool enabled) {
    final Color fg = enabled ? AppColors.videoText : AppColors.videoMuted.withValues(alpha: 0.45);
    final Widget body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Delete 键映射为 Backspace', style: TextStyle(fontSize: 12.5, color: fg)),
                const SizedBox(height: 1),
                Text(
                  enabled ? 'Mac 键盘上的 Delete 其实等于是退格' : '两边键盘布局一致',
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.3,
                    color: enabled ? AppColors.videoMuted : fg,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          _MiniSwitch(
            value: config.deleteAsBackspace,
            onChanged: enabled
                ? (bool v) => onChanged(config.copyWith(deleteAsBackspace: v))
                : null,
          ),
        ],
      ),
    );

    if (!enabled) return body;
    return InkWell(
      onTap: () => onChanged(config.copyWith(deleteAsBackspace: !config.deleteAsBackspace)),
      child: body,
    );
  }

  Widget _footer() {
    final String text = _sameOs
        ? '同平台直连，键位直通'
        : describeMapping(localOs, remoteOs, config);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 7, 12, 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.videoChromeBorder)),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 10.5, height: 1.45, color: AppColors.videoMuted),
      ),
    );
  }
}

/// 紧凑开关：与 `security_panel` 同款，这里多一个可空回调用作置灰。
class _MiniSwitch extends StatelessWidget {
  const _MiniSwitch({required this.value, required this.onChanged});

  final bool value;

  /// null 表示不可操作（置灰）。
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onChanged != null;
    return GestureDetector(
      onTap: enabled ? () => onChanged!(!value) : null,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 34,
          height: 19,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: value
                ? (enabled ? AppColors.accent : AppColors.accent.withValues(alpha: 0.35))
                : AppColors.videoBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: value
                  ? (enabled ? AppColors.accent : AppColors.accent.withValues(alpha: 0.35))
                  : AppColors.videoChromeBorder,
            ),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 120),
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: enabled ? 1 : 0.6),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 弹出外设面板（键位映射）。范式与安全/画质/鼠标面板一致。
Future<void> showPeripheralPanel(
  BuildContext context, {
  required KeyMappingConfig config,
  required String localOs,
  required String remoteOs,
  required ValueChanged<KeyMappingConfig> onChanged,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '外设设置',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (BuildContext ctx, Animation<double> a, Animation<double> b) =>
        const SizedBox.shrink(),
    transitionBuilder:
        (BuildContext ctx, Animation<double> anim, Animation<double> b, Widget child) {
      return FadeTransition(
        opacity: anim,
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 52, right: 10, bottom: 56),
            child: GlassPanel(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: SizedBox(
                width: 320,
                child: PeripheralPanel(
                  config: config,
                  localOs: localOs,
                  remoteOs: remoteOs,
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
