import 'package:material_ui/material_ui.dart';

import '../core/mouse_mode.dart';
import '../core/theme.dart';
import 'ui_kit.dart';

/// 鼠标模式下拉内容（官方「鼠标」菜单）。
///
/// 三档单选 + 游戏鼠标模式 + 指针速度，改动即时通过 [onChanged] 上报。
/// **不自带背景**：宽 300，放进 `GlassPanel` 或 `videoChrome` 弹出层。
///
/// 两处「点了没用」的坑都在这里挡掉：
/// - 被控端不支持隐藏系统光标时，「使用主控端鼠标」整行置灰并说明原因；
/// - 只有在「使用主控端鼠标」下，游戏鼠标模式与速度才可调。
class MousePanel extends StatelessWidget {
  const MousePanel({
    super.key,
    required this.settings,
    required this.cursorSupported,
    required this.onChanged,
  });

  final MouseSettings settings;

  /// 被控端能否隐藏自己的系统光标。false 时主控端鼠标接管没有意义。
  final bool cursorSupported;

  final ValueChanged<MouseSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    final bool controlActive = settings.mode == MouseMode.control;
    return SizedBox(
      width: 300,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text('鼠标模式', style: TextStyle(fontSize: 11, color: AppColors.videoMuted)),
          ),
          for (final MouseMode m in MouseMode.values) _modeRow(m),
          _divider(),
          _gameModeRow(enabled: controlActive),
          if (controlActive && settings.gameMode) _speedRow(context),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _modeRow(MouseMode mode) {
    final bool on = settings.mode == mode;
    final bool blocked = mode == MouseMode.control && !cursorSupported;
    final Color fg = blocked
        ? AppColors.videoMuted.withValues(alpha: 0.45)
        : (on ? AppColors.videoText : AppColors.videoMuted);

    final Widget row = InkWell(
      onTap: blocked ? null : () => onChanged(settings.copyWith(mode: mode)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                on ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 15,
                color: on ? AppColors.accent : fg,
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    mode.label,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.2,
                      color: fg,
                      fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(mode.hint, style: TextStyle(fontSize: 10.5, height: 1.3, color: fg)),
                  // 切回被控端鼠标后光标会重新出现，第一次用的人常以为「鼠标还在」
                  if (mode == MouseMode.remote)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '切回被控端鼠标后，远端光标会重新出现',
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.3,
                          color: AppColors.videoMuted.withValues(alpha: on ? 0.9 : 0.7),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            _dot(on: on),
          ],
        ),
      ),
    );

    if (!blocked) return row;
    return Tooltip(
      message: '当前被控端不支持隐藏系统光标',
      child: MouseRegion(cursor: SystemMouseCursors.basic, child: row),
    );
  }

  /// 行尾状态点：实心＝当前生效，描边灰＝未生效。
  Widget _dot({required bool on}) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Tooltip(
        message: on ? '当前生效' : '未生效',
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? AppColors.accent : AppColors.videoChromeBorder,
          ),
        ),
      ),
    );
  }

  Widget _gameModeRow({required bool enabled}) {
    final Color fg = enabled ? AppColors.videoText : AppColors.videoMuted.withValues(alpha: 0.45);
    final Widget body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        children: <Widget>[
          Icon(Icons.sports_esports_outlined, size: 16, color: enabled ? AppColors.accent : fg),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('游戏鼠标模式', style: TextStyle(fontSize: 12.5, color: fg)),
                Text(
                  enabled ? '按相对位移上报，适合需要锁定指针的游戏' : '仅在『使用主控端鼠标』下生效',
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
            value: settings.gameMode,
            onChanged: enabled ? (bool v) => onChanged(settings.copyWith(gameMode: v)) : null,
          ),
        ],
      ),
    );

    if (!enabled) {
      return Tooltip(
        message: '仅在『使用主控端鼠标』下生效',
        child: MouseRegion(cursor: SystemMouseCursors.basic, child: body),
      );
    }
    return InkWell(
      onTap: () => onChanged(settings.copyWith(gameMode: !settings.gameMode)),
      child: body,
    );
  }

  Widget _speedRow(BuildContext context) {
    final double speed = settings.speed
        .clamp(MouseSettings.minSpeed, MouseSettings.maxSpeed)
        .toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text('速度', style: TextStyle(fontSize: 11, color: AppColors.videoMuted)),
              const Spacer(),
              Text(
                '×${speed.toStringAsFixed(1)}',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.videoText,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: AppColors.accent,
              inactiveTrackColor: AppColors.videoChromeBorder,
              thumbColor: AppColors.accent,
            ),
            child: Slider(
              value: speed,
              min: MouseSettings.minSpeed,
              max: MouseSettings.maxSpeed,
              // 0.5–3.0 共 25 段，正好 0.1 一格
              divisions: 25,
              onChanged: (double v) => onChanged(settings.copyWith(speed: (v * 10).roundToDouble() / 10)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() => Container(
        height: 1,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: AppColors.videoChromeBorder,
      );
}

/// 紧凑开关：系统 `Switch` 在弹出面板里太占地方，且禁用态难以整体变灰。
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

/// 弹出鼠标设置面板（与安全/画质面板同一套 `showGeneralDialog` 范式）。
///
/// 贴右上角、避开 46px 顶栏：这三个面板都从顶栏按钮拉下来，
/// 位置一致用户才不会每次都重新找。
Future<void> showMousePanel(
  BuildContext context, {
  required MouseSettings settings,
  required bool cursorSupported,
  required ValueChanged<MouseSettings> onChanged,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '鼠标设置',
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
                width: 300,
                child: MousePanel(
                  settings: settings,
                  cursorSupported: cursorSupported,
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
