import 'dart:ui' show FontFeature, ImageFilter;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// 组件层：页面只拼这些积木，不各自写 BoxDecoration。

/// 状态点：在线带呼吸动画，离线为静态灰点。
class StatusDot extends StatefulWidget {
  const StatusDot({super.key, required this.color, this.pulse = false, this.size = 8});

  final Color color;
  final bool pulse;
  final double size;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant StatusDot old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.pulse && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (BuildContext context, _) {
        final double glow = widget.pulse ? 0.25 + 0.25 * _ctrl.value : 0;
        return SizedBox(
          width: widget.size + 8,
          height: widget.size + 8,
          child: Center(
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
                boxShadow: glow == 0
                    ? null
                    : <BoxShadow>[BoxShadow(color: widget.color.withValues(alpha: glow), blurRadius: 6, spreadRadius: 1)],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 浅色胶囊标签：默认浅灰底深字，[filled] 时用强调色实底白字。
class Pill extends StatelessWidget {
  const Pill({super.key, required this.text, this.color = AppColors.muted, this.filled = false, this.icon});

  final String text;
  final Color color;
  final bool filled;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final Color bg = filled ? color : color.withValues(alpha: 0.10);
    final Color fg = filled ? Colors.white : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(AppRadius.pill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.25,
              color: fg,
              fontWeight: filled ? FontWeight.w600 : FontWeight.w500,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// 缩略图左上角的在线状态胶囊：半透明黑底 + 绿点 + 白字。
class StatusCapsule extends StatelessWidget {
  const StatusCapsule({super.key, required this.online, this.label});

  final bool online;
  final String? label;

  @override
  Widget build(BuildContext context) {
    if (!online) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(color: const Color(0xA6000000), borderRadius: BorderRadius.circular(AppRadius.pill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 5,
            height: 5,
            decoration: const BoxDecoration(color: AppColors.online, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            label ?? '在线',
            style: const TextStyle(fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w500, height: 1.2),
          ),
        ],
      ),
    );
  }
}

/// 分组头：左边「在线设备 3」，右侧折叠箭头。整行可点。
class GroupHeader extends StatelessWidget {
  const GroupHeader({super.key, required this.text, required this.count, required this.expanded, this.onTap, this.trailing});

  final String text;
  final int count;
  final bool expanded;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 4, left: 2, right: 2),
        child: Row(
          children: <Widget>[
            Text(
              '$text $count',
              style: const TextStyle(fontSize: 13.5, color: Color(0xFF5C6166), fontWeight: FontWeight.w600),
            ),
            if (trailing != null) ...<Widget>[const SizedBox(width: 8), trailing!],
            const Spacer(),
            AnimatedRotation(
              turns: expanded ? 0 : 0.5,
              duration: const Duration(milliseconds: 160),
              child: const Icon(Icons.keyboard_arrow_up, size: 17, color: Color(0xFF9AA0A6)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 白色圆角卡片：浅色主题下靠底色对比分层，不加边框和重阴影。
class AppCard extends StatefulWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(AppSpace.lg),
    this.selected = false,
    this.margin = EdgeInsets.zero,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final bool selected;
  final EdgeInsets margin;

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.margin,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: widget.selected ? AppColors.accent : (_hover ? AppColors.borderStrong : Colors.transparent),
            width: widget.selected ? 1.4 : 1,
          ),
          boxShadow: AppShadows.card,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (bool v) => setState(() => _hover = v),
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Padding(padding: widget.padding, child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// 设备缩略图占位：官方稿是实时画面截屏，我们暂无该接口，
/// 用「平台色渐变 + 平台图标」表示，不伪造真实画面。
class DeviceThumb extends StatelessWidget {
  const DeviceThumb({
    super.key,
    required this.width,
    required this.height,
    required this.icon,
    required this.online,
    this.radius = const BorderRadius.horizontal(left: Radius.circular(AppRadius.md)),
    this.statusLabel,
  });

  final double width;
  final double height;
  final IconData icon;
  final bool online;
  final BorderRadius radius;
  final String? statusLabel;

  @override
  Widget build(BuildContext context) {
    final List<Color> colors = online
        ? <Color>[const Color(0xFF4A90FF), const Color(0xFF3478F6)]
        : <Color>[const Color(0xFFE3E7EB), const Color(0xFFD2D8DE)];
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: colors,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
            Center(
              child: Icon(icon, size: 22, color: online ? Colors.white : const Color(0xFF7E8791)),
            ),
            Positioned(
              left: 6,
              top: 6,
              child: StatusCapsule(online: online, label: statusLabel),
            ),
          ],
        ),
      ),
    );
  }
}

/// 远控画面上的玻璃层：视频区是深色，所以这里固定用深色半透明 + 模糊。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    this.radius = AppRadius.md,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: AppColors.videoChrome,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: borderColor ?? AppColors.videoChromeBorder),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 远控工具条按钮：图标 + 可选角标，带按下/激活态。
class ToolButton extends StatefulWidget {
  const ToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.active = false,
    this.badge,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;
  final String? badge;

  /// 危险操作（断开/退出）用红色
  final bool danger;

  @override
  State<ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<ToolButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final bool on = widget.active;
    final Color fg = widget.danger ? AppColors.danger : (on ? AppColors.accent : AppColors.videoText);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: widget.onPressed == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTapDown: widget.onPressed == null ? null : (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: on
                    ? AppColors.accent.withValues(alpha: 0.18)
                    : (_hover || _down ? Colors.white.withValues(alpha: 0.10) : Colors.transparent),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: on ? AppColors.accent.withValues(alpha: 0.5) : Colors.transparent),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  Icon(widget.icon, size: 19, color: fg),
                  if (widget.badge != null)
                    Positioned(
                      right: 5,
                      top: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        constraints: const BoxConstraints(minWidth: 13, minHeight: 13),
                        decoration: BoxDecoration(color: AppColors.danger, borderRadius: BorderRadius.circular(7)),
                        alignment: Alignment.center,
                        child: Text(
                          widget.badge!,
                          style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w600, height: 1.2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 画面角上的信息小条（分辨率 / 帧率 / 延迟 / 通路）。
class HudChip extends StatelessWidget {
  const HudChip({super.key, required this.text, this.icon, this.color});

  final String text;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: 12, color: color ?? AppColors.videoMuted),
          const SizedBox(width: 4),
        ],
        Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            color: color ?? AppColors.videoMuted,
            fontWeight: FontWeight.w500,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// 空态 / 错误态：图标 + 标题 + 说明 + 可选主按钮。
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, this.icon, required this.title, this.message, this.action});

  final IconData? icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 68,
              height: 68,
              decoration: const BoxDecoration(color: AppColors.surface, shape: BoxShape.circle, boxShadow: AppShadows.card),
              child: Icon(icon ?? Icons.devices_other_outlined, size: 30, color: AppColors.faint),
            ),
            const SizedBox(height: AppSpace.lg),
            Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            if (message != null) ...<Widget>[
              const SizedBox(height: AppSpace.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: AppColors.muted, height: 1.6),
                ),
              ),
            ],
            if (action != null) ...<Widget>[const SizedBox(height: AppSpace.xl), action!],
          ],
        ),
      ),
    );
  }
}

/// 加载态：转圈 + 文案。
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.text});

  final String? text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: AppColors.accent),
          ),
          if (text != null) ...<Widget>[
            const SizedBox(height: AppSpace.md),
            Text(text!, style: const TextStyle(fontSize: 13, color: AppColors.muted)),
          ],
        ],
      ),
    );
  }
}

/// 小标题：文字 + 右侧渐隐细线。
class SectionLabel extends StatelessWidget {
  const SectionLabel({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Row(
        children: <Widget>[
          Text(
            text,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.muted, letterSpacing: 0.3),
          ),
          const SizedBox(width: AppSpace.md),
          const Expanded(child: Divider(height: 1, color: AppColors.border)),
        ],
      ),
    );
  }
}