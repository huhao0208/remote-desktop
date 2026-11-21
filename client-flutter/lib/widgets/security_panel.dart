import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../core/security.dart';
import '../core/theme.dart';

/// 安全下拉面板（官方 B2.3）。
///
/// 三段结构：安全状态标题 → 防窥四档 → 自动锁屏 / 被控静音。
/// 平台做不了的档位（`engine != overlay`）整组置灰并给出一句原因，
/// 不做「点了没反应」这种最烦人的交互。
Future<void> showSecurityPanel(
  BuildContext context, {
  required ValueListenable<SecurityState> state,
  required ValueChanged<PrivacyMode> onPrivacy,
  required ValueChanged<bool> onAutoLock,
  required ValueChanged<bool> onMute,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '安全设置',
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
            child: _SecurityPanel(
              initial: state,
              onPrivacy: onPrivacy,
              onAutoLock: onAutoLock,
              onMute: onMute,
            ),
          ),
        ),
      );
    },
  );
}

class _SecurityPanel extends StatefulWidget {
  const _SecurityPanel({
    required this.initial,
    required this.onPrivacy,
    required this.onAutoLock,
    required this.onMute,
  });

  final ValueListenable<SecurityState> initial;
  final ValueChanged<PrivacyMode> onPrivacy;
  final ValueChanged<bool> onAutoLock;
  final ValueChanged<bool> onMute;

  @override
  State<_SecurityPanel> createState() => _SecurityPanelState();
}

class _SecurityPanelState extends State<_SecurityPanel> {
  late SecurityState _s = widget.initial.value;

  @override
  void initState() {
    super.initState();
    // 被控端回执可能推翻本地点亮（例如「当前平台不支持防窥」），
    // 面板必须跟着回退，否则用户以为已经开了
    widget.initial.addListener(_onExternal);
  }

  @override
  void dispose() {
    widget.initial.removeListener(_onExternal);
    super.dispose();
  }

  void _onExternal() {
    if (!mounted) return;
    setState(() => _s = widget.initial.value);
  }

  @override
  Widget build(BuildContext context) {
    final bool supported = _s.privacySupported;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 322,
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
            _header(),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (_s.error != null) _errorBar(_s.error!),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(14, 2, 14, 4),
                      child: Text('防窥模式',
                          style: TextStyle(fontSize: 11, color: AppColors.videoMuted)),
                    ),
                    for (final PrivacyMode m in PrivacyMode.values) _modeRow(m, supported),
                    if (!supported) _unsupportedNote(),
                    _divider(),
                    _switchRow(
                      icon: Icons.lock_clock,
                      title: '自动锁屏',
                      subtitle: '结束远程后自动锁定被控端',
                      value: _s.autoLock,
                      onChanged: (bool v) {
                        setState(() => _s = _s.copyWith(autoLock: v, clearError: true));
                        widget.onAutoLock(v);
                      },
                    ),
                    _switchRow(
                      icon: _s.muted ? Icons.volume_off : Icons.volume_up,
                      title: '被控静音',
                      subtitle: _s.muted ? '已静音（控制端仍可听）' : '已外放',
                      value: _s.muted,
                      onChanged: (bool v) {
                        setState(() => _s = _s.copyWith(muted: v, clearError: true));
                        widget.onMute(v);
                      },
                    ),
                  ],
                ),
              ),
            ),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final bool ok = _s.protectedNow;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
      child: Row(
        children: <Widget>[
          Icon(ok ? Icons.verified_user : Icons.gpp_maybe,
              size: 15, color: ok ? AppColors.online : AppColors.warn),
          const SizedBox(width: 6),
          Text(
            ok ? '已防护' : '需关注',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: ok ? AppColors.online : AppColors.warn,
            ),
          ),
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
    );
  }

  Widget _errorBar(String text) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 11, height: 1.35, color: AppColors.danger)),
    );
  }

  Widget _modeRow(PrivacyMode m, bool supported) {
    final bool on = _s.privacy == m;
    // 隐私屏保：协议与 Agent 都支持，但客户端还没做「选图 + 上传」链路，
    // 先置灰（选中的话仍可切回别的档，不至于卡死）
    final bool pendingWallpaper = m == PrivacyMode.wallpaper && !on;
    final bool enabled = supported && !pendingWallpaper;

    final Color fg = enabled
        ? (on ? AppColors.videoText : AppColors.videoMuted)
        : AppColors.videoMuted.withValues(alpha: 0.45);

    return InkWell(
      onTap: enabled ? () {
        setState(() => _s = _s.copyWith(privacy: m, clearError: true));
        widget.onPrivacy(m);
      } : null,
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
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        m.label,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.2,
                          color: fg,
                          fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      if (pendingWallpaper) ...<Widget>[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            border: Border.all(color: AppColors.videoChromeBorder),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: const Text('待做',
                              style: TextStyle(fontSize: 9, color: AppColors.videoMuted)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 1),
                  Text(
                    m.hint,
                    style: TextStyle(fontSize: 10.5, height: 1.3, color: fg),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _unsupportedNote() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: const Text(
        '当前被控端无法做防窥：遮罩窗会被屏幕采集一起录进去，熄屏又会让采集断流。'
        '下面两项仍然可用。',
        style: TextStyle(fontSize: 10.5, height: 1.4, color: AppColors.warn),
      ),
    );
  }

  Widget _switchRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 16, color: value ? AppColors.accent : AppColors.videoMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title,
                      style: const TextStyle(fontSize: 12.5, color: AppColors.videoText)),
                  Text(subtitle,
                      style: const TextStyle(fontSize: 10.5, color: AppColors.videoMuted)),
                ],
              ),
            ),
            _MiniSwitch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }

  Widget _divider() => Container(
        height: 1,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: AppColors.videoChromeBorder,
      );

  Widget _footer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.videoChromeBorder)),
      ),
      child: Row(
        children: <Widget>[
          const Expanded(
            child: Text(
              '防窥与锁屏均作用于被控端本机',
              style: TextStyle(fontSize: 10.5, color: AppColors.videoMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            style: TextButton.styleFrom(
              minimumSize: const Size(56, 28),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('完成', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// 紧凑开关：系统 `Switch` 在 46px 顶栏面板里太占地方。
class _MiniSwitch extends StatelessWidget {
  const _MiniSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 34,
        height: 19,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: value ? AppColors.accent : AppColors.videoBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: value ? AppColors.accent : AppColors.videoChromeBorder,
          ),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 120),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 13,
            height: 13,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}
