import 'package:material_ui/material_ui.dart';

import '../core/mini_window.dart';
import '../core/theme.dart';

/// 小窗模式设置（官方 B5）：置顶、不透明度、尺寸档、可拖动、退出。
///
/// 为什么单独一个面板而不是直接切开关：官方小窗的核心是「一边干活一边瞟」，
/// 透明度和尺寸调一次就长期用，必须能记住；只有一个开关的话用户每次都要重调。
class MiniWindowPanel extends StatefulWidget {
  const MiniWindowPanel({
    required this.state,
    required this.onChange,
    required this.onExitMini,
    this.supported = true,
    super.key,
  });

  final MiniWindowState state;

  /// 每次改动立刻回传（拖动滑块时调用方自己做防抖/直接应用）。
  final ValueChanged<MiniWindowState> onChange;

  /// 退出小窗模式（恢复原窗口）。
  final VoidCallback onExitMini;

  /// 平台是否支持（移动端为 false，整组置灰并说明）。
  final bool supported;

  @override
  State<MiniWindowPanel> createState() => _MiniWindowPanelState();
}

class _MiniWindowPanelState extends State<MiniWindowPanel> {
  late MiniWindowState _state = widget.state;

  void _apply(MiniWindowState next) {
    setState(() => _state = next);
    widget.onChange(next);
  }

  @override
  Widget build(BuildContext context) {
    final bool on = _state.enabled;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.sm, AppSpace.sm),
            child: Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    '小窗模式',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    ),
                  ),
                ),
                if (on)
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('完成'),
                  ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          if (!widget.supported)
            _unsupported()
          else ...<Widget>[
            _switchRow(
              title: '置顶显示',
              subtitle: '小窗浮在其他窗口之上，不置顶就等于普通窗口',
              value: _state.alwaysOnTop,
              onChanged: (bool v) => _apply(_state.copyWith(alwaysOnTop: v)),
            ),
            _switchRow(
              title: '允许拖动',
              subtitle: '关掉后窗口钉在原地，防止误拖找不到',
              value: _state.movable,
              onChanged: (bool v) => _apply(_state.copyWith(movable: v)),
            ),
            _opacityRow(),
            _sizeRow(),
            if (on)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.lg),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      widget.onExitMini();
                      Navigator.of(context).maybePop();
                    },
                    icon: const Icon(Icons.close_fullscreen, size: 16),
                    label: const Text('退出小窗模式'),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.lg),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _apply(_state.copyWith(enabled: true)),
                    icon: const Icon(Icons.picture_in_picture_alt, size: 16),
                    label: const Text('进入小窗模式'),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _unsupported() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
      child: Row(
        children: <Widget>[
          const Icon(Icons.info_outline, size: 15, color: AppColors.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '小窗模式只在桌面端可用（依赖操作系统窗口管理），手机/平板上没有「浮窗置顶」这个概念',
              style: TextStyle(fontSize: 12, color: AppColors.muted.withValues(alpha: 0.9), height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _switchRow({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile.adaptive(
      value: value,
      onChanged: onChanged,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
      title: Text(title, style: const TextStyle(fontSize: 13.5, color: AppColors.text)),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 11.5, color: AppColors.muted, height: 1.4),
      ),
    );
  }

  Widget _opacityRow() {
    final int percent = (_state.opacity * 100).round();
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text('不透明度', style: TextStyle(fontSize: 13.5, color: AppColors.text)),
              const Spacer(),
              Text(
                '$percent%',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.muted,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          Slider(
            // 下限抬到 0.5：整窗透明会把控制条一起变淡，低于这个值按钮基本看不清
            value: _state.opacity.clamp(0.5, 1.0),
            min: 0.5,
            max: 1.0,
            divisions: 10,
            label: '$percent%',
            onChanged: (double v) => _apply(_state.copyWith(opacity: v)),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpace.sm),
            child: Text(
              '整窗透明度会把按钮一起变淡，所以最低只到 50%',
              style: TextStyle(fontSize: 11, color: AppColors.faint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sizeRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('窗口尺寸', style: TextStyle(fontSize: 13.5, color: AppColors.text)),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: <Widget>[
              for (final MiniWindowSize size in MiniWindowSize.values) ...<Widget>[
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _sizeChip(size),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpace.md),
        ],
      ),
    );
  }

  Widget _sizeChip(MiniWindowSize size) {
    final bool active = _state.size == size;
    return InkWell(
      onTap: () => _apply(_state.copyWith(size: size)),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? AppColors.accentDim : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: active ? AppColors.accent : AppColors.border),
        ),
        child: Text(
          size.label,
          style: TextStyle(
            fontSize: 12.5,
            color: active ? AppColors.accent : AppColors.text,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// 打开小窗面板。
Future<void> showMiniWindowPanel(
  BuildContext context, {
  required MiniWindowState state,
  required ValueChanged<MiniWindowState> onChange,
  required VoidCallback onExitMini,
  bool supported = true,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) => MiniWindowPanel(
      state: state,
      onChange: onChange,
      onExitMini: onExitMini,
      supported: supported,
    ),
  );
}
