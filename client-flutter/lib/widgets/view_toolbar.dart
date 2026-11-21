import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../core/view_mode.dart';
import 'ui_kit.dart';

/// 观看模式浮条（官方 B4）：拖拽浏览 / 批注 / 放大 / 缩小 / 复位 / 退出 / 隐藏。
///
/// 为什么独立成条而不是塞进底栏：观看和操控是两种「心境」，底栏是操控期的
/// 常用动作（键盘、粘贴、Ctrl+Alt+Del），观看期一个都用不上。混在一起会让
/// 用户在两种态下都要在一排图标里找东西。
class ViewToolbar extends StatelessWidget {
  const ViewToolbar({
    required this.state,
    required this.scale,
    required this.onToggleAnnotation,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onResetZoom,
    required this.onExitView,
    required this.onHide,
    this.annotationFull = false,
    super.key,
  });

  /// 当前三态（操控态不该显示这条，由调用方决定）。
  final ViewState state;

  /// 当前缩放倍数，显示在缩放按钮之间。
  final double scale;

  final VoidCallback onToggleAnnotation;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onResetZoom;
  final VoidCallback onExitView;
  final VoidCallback onHide;

  /// 批注笔画已满（`AnnotationBoard.maxStrokes`）。
  /// 满了要让用户看见原因，否则点「批注」毫无反应。
  final bool annotationFull;

  @override
  Widget build(BuildContext context) {
    final bool annotating = state == ViewState.annotation;
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 5),
      radius: AppRadius.md,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _chip(
            icon: Icons.back_hand_outlined,
            label: '拖拽',
            active: state == ViewState.view,
            tip: '观看模式：拖拽可平移画面，输入不会发给被控端',
            onTap: () {},
          ),
          _chip(
            icon: Icons.edit_outlined,
            label: annotationFull ? '批注（已满）' : '批注',
            active: annotating,
            tip: annotationFull ? '批注太多，先清空再画' : '在画面上做标注（只在本机可见）',
            onTap: onToggleAnnotation,
            danger: annotationFull,
          ),
          const _ViewDivider(),
          _icon(
            icon: Icons.zoom_out,
            tip: '缩小（⌘-）',
            onTap: onZoomOut,
          ),
          Tooltip(
            message: '点击复位到 100%',
            child: InkWell(
              onTap: onResetZoom,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Container(
                height: 30,
                constraints: const BoxConstraints(minWidth: 46),
                alignment: Alignment.center,
                child: Text(
                  '${(scale * 100).round()}%',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scale == 1.0 ? AppColors.videoMuted : AppColors.accent,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
          _icon(
            icon: Icons.zoom_in,
            tip: '放大（⌘=）',
            onTap: onZoomIn,
          ),
          const _ViewDivider(),
          _chip(
            icon: Icons.close_fullscreen,
            label: '退出观看',
            tip: '回到操控模式（输入重新发给被控端）',
            onTap: onExitView,
          ),
          _icon(
            icon: Icons.keyboard_arrow_down,
            tip: '隐藏工具条（⌘⇧T 可再显示）',
            onTap: onHide,
          ),
        ],
      ),
    );
  }

  Widget _icon({
    required IconData icon,
    required String tip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tip,
      child: InkResponse(
        onTap: onTap,
        radius: 18,
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(icon, size: 17, color: AppColors.videoText),
        ),
      ),
    );
  }

  Widget _chip({
    required IconData icon,
    required String label,
    required String tip,
    required VoidCallback onTap,
    bool active = false,
    bool danger = false,
  }) {
    final Color fg = danger
        ? AppColors.warn
        : (active ? AppColors.accent : AppColors.videoText);
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: active ? AppColors.accent.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
              color: active ? AppColors.accent.withValues(alpha: 0.5) : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ViewDivider extends StatelessWidget {
  const _ViewDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: AppColors.videoChromeBorder,
    );
  }
}

/// 观看模式提示（首帧后首次切入观看时显示一次，告诉用户输入已拦截）。
class ViewModeHint extends StatelessWidget {
  const ViewModeHint({required this.state, super.key});

  final ViewState state;

  @override
  Widget build(BuildContext context) {
    if (state == ViewState.control) return const SizedBox.shrink();
    final String text = state == ViewState.annotation
        ? '批注模式：手势只画在本机，不会操作被控端'
        : '观看模式：输入不会发给被控端，拖拽可平移画面';
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.warn.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.visibility, size: 13, color: Colors.black87),
            const SizedBox(width: 5),
            Text(
              text,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.black87,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
