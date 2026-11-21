import 'package:material_ui/material_ui.dart';

import '../core/security.dart';
import '../core/theme.dart';

/// 电源下拉（官方「工具」菜单里的锁屏/重启/关机/任务管理器）。
///
/// 关机与重启**不立即执行**：先弹确认，再由被控端倒计时 30 秒，
/// 期间画面上方常驻撤销条。远控里误点关机等于把机器关在门外，
/// 多这两步比事后追责便宜得多。
Future<void> showPowerPanel(
  BuildContext context, {
  required bool Function(String action) supports,
  required ValueChanged<PowerAction> onAction,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '电源',
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
            child: _PowerPanel(supports: supports, onAction: onAction),
          ),
        ),
      );
    },
  );
}

class _PowerPanel extends StatelessWidget {
  const _PowerPanel({required this.supports, required this.onAction});

  final bool Function(String action) supports;
  final ValueChanged<PowerAction> onAction;

  static const Map<PowerAction, IconData> _icons = <PowerAction, IconData>{
    PowerAction.lock: Icons.lock_outline,
    PowerAction.reboot: Icons.restart_alt,
    PowerAction.shutdown: Icons.power_settings_new,
    PowerAction.taskmgr: Icons.monitor_heart_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 268,
        decoration: BoxDecoration(
          color: AppColors.videoChrome,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.videoChromeBorder),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 26,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
              child: Row(
                children: <Widget>[
                  const Text('电源',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.videoText)),
                  const Spacer(),
                  InkWell(
                    onTap: () => Navigator.of(context).maybePop(),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close, size: 16, color: AppColors.videoMuted),
                    ),
                  ),
                ],
              ),
            ),
            for (final PowerAction a in PowerAction.values)
              _row(context, a, supports(a.key)),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, PowerAction a, bool enabled) {
    final bool danger = a == PowerAction.shutdown || a == PowerAction.reboot;
    final Color fg = !enabled
        ? AppColors.videoMuted.withValues(alpha: 0.45)
        : (danger ? AppColors.danger : AppColors.videoText);
    return InkWell(
      onTap: enabled
          ? () async {
              Navigator.of(context).maybePop();
              if (a.needsCountdown) {
                final bool ok = await _confirm(context, a);
                if (!ok) return;
              }
              onAction(a);
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: <Widget>[
            Icon(_icons[a], size: 17, color: fg),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(a.label, style: TextStyle(fontSize: 12.5, color: fg)),
                  Text(
                    enabled ? a.hint : '当前被控端不支持',
                    style: const TextStyle(fontSize: 10.5, color: AppColors.videoMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirm(BuildContext context, PowerAction a) async {
    final bool timed = a.needsCountdown;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: AppColors.videoChrome,
        title: Text('${a.label}被控端？',
            style: const TextStyle(fontSize: 15, color: AppColors.videoText)),
        content: Text(
          timed
              ? '将向被控端发送${a.label}指令，30 秒后执行。\n这 30 秒内可以在画面上方撤销。'
              : '将立即${a.label}。',
          style: const TextStyle(fontSize: 12.5, height: 1.5, color: AppColors.videoMuted),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: Text(a.label),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

/// 关机/重启倒计时条：压在画面顶部，永远盖在视频之上。
class PowerCountdownBanner extends StatelessWidget {
  const PowerCountdownBanner({
    super.key,
    required this.countdown,
    required this.onCancel,
  });

  final PowerCountdown countdown;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.power_settings_new, size: 16, color: Colors.white),
          const SizedBox(width: 8),
          Text(
            '${countdown.action.label}将在 ${countdown.remain} 秒后执行',
            style: const TextStyle(fontSize: 12, color: Colors.white),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: onCancel,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: Colors.white.withValues(alpha: 0.18),
              minimumSize: const Size(48, 26),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('撤销', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
