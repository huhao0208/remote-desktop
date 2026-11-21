import 'package:material_ui/material_ui.dart';

import '../core/client_lock.dart';
import '../core/lock_service.dart';
import '../core/theme.dart';

/// 客户端锁设置（官方 B6.3）：8–16 位密码 + 三种自动锁定策略。
///
/// 三种策略的语义差异很容易被误解，所以每条都写了一句副标题：
/// 尤其是「远程协助期间锁定」——它的意思是**别人远程控制本机时**把控制端锁上，
/// 防止事后被翻看，而不是「远程时把自己锁在外面」。
class ClientLockPanel extends StatefulWidget {
  const ClientLockPanel({required this.onChanged, super.key});

  /// 锁定状态/配置变了，通知父级刷新（「我的」页要更新副标题）。
  final VoidCallback onChanged;

  @override
  State<ClientLockPanel> createState() => _ClientLockPanelState();
}

class _ClientLockPanelState extends State<ClientLockPanel> {
  ClientLock get _lock => LockService.instance.client;

  bool _busy = false;

  Future<void> _setPasswordDialog({required bool changing}) async {
    final TextEditingController first = TextEditingController();
    final TextEditingController second = TextEditingController();
    String? error;

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setLocal) {
          Future<void> submit() async {
            if (first.text != second.text) {
              setLocal(() => error = '两次输入的密码不一致');
              return;
            }
            setLocal(() => error = null);
            final String? failure = await _lock.setPassword(first.text);
            if (failure != null) {
              setLocal(() => error = failure);
              return;
            }
            if (ctx.mounted) Navigator.of(ctx).pop(true);
          }

          return AlertDialog(
            title: Text(changing ? '修改安全密码' : '设置安全密码'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: first,
                  obscureText: true,
                  maxLength: ClientLock.maxLength,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '安全密码（8–16 位）',
                    counterText: '',
                    helperText: '至少包含字母和数字两类字符',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppSpace.sm),
                TextField(
                  controller: second,
                  obscureText: true,
                  maxLength: ClientLock.maxLength,
                  onSubmitted: (_) => submit(),
                  decoration: InputDecoration(
                    labelText: '再输入一次',
                    counterText: '',
                    errorText: error,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: const Text('保存')),
            ],
          );
        },
      ),
    );
    first.dispose();
    second.dispose();
    if (ok == true) {
      widget.onChanged();
      if (mounted) setState(() {});
    }
  }

  Future<void> _clearPassword() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('关闭客户端锁？'),
        content: const Text(
          '会同时清除安全密码和三个自动锁定开关。之后任何人打开这个客户端都不需要密码。',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('关闭并清除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _lock.clearPassword();
    widget.onChanged();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final bool hasPassword = _lock.hasPassword;
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
                    '安全锁定',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          if (!hasPassword) ...<Widget>[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpace.lg),
              child: Text(
                '设一个安全密码后，可以指定在启动时、关闭主界面时、或被别人远程协助期间自动锁定客户端。'
                '密码只保存摘要，不会明文落盘。',
                style: TextStyle(fontSize: 12.5, color: AppColors.muted, height: 1.6),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.lg, AppSpace.lg),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _setPasswordDialog(changing: false),
                  icon: const Icon(Icons.lock_outline, size: 16),
                  label: const Text('设置安全密码'),
                ),
              ),
            ),
          ] else ...<Widget>[
            for (final AutoLockTrigger trigger in AutoLockTrigger.values)
              SwitchListTile.adaptive(
                value: _lock.isTriggerEnabled(trigger),
                onChanged: _busy
                    ? null
                    : (bool v) async {
                        setState(() => _busy = true);
                        await _lock.setTrigger(trigger, v);
                        widget.onChanged();
                        if (mounted) setState(() => _busy = false);
                      },
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                title: Text(
                  trigger.label,
                  style: const TextStyle(fontSize: 13.5, color: AppColors.text),
                ),
                subtitle: Text(
                  trigger.hint,
                  style: const TextStyle(fontSize: 11.5, color: AppColors.muted, height: 1.4),
                ),
              ),
            const Divider(height: 1),
            _action(
              icon: Icons.password,
              label: '修改安全密码',
              onTap: () => _setPasswordDialog(changing: true),
            ),
            _action(
              icon: Icons.lock_clock,
              label: '立即锁定',
              onTap: () {
                LockService.instance.lock();
                Navigator.of(context).maybePop();
              },
            ),
            _action(
              icon: Icons.lock_open,
              label: '关闭客户端锁',
              danger: true,
              onTap: _clearPassword,
            ),
            const SizedBox(height: AppSpace.sm),
          ],
        ],
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final Color color = danger ? AppColors.danger : AppColors.text;
    return InkWell(
      onTap: _busy ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: 13),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: danger ? AppColors.danger : AppColors.muted),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Text(label, style: TextStyle(fontSize: 13.5, color: color)),
            ),
            Icon(Icons.chevron_right, size: 16, color: AppColors.faint),
          ],
        ),
      ),
    );
  }
}

/// 打开客户端锁设置。
Future<void> showClientLockPanel(BuildContext context, {required VoidCallback onChanged}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) => ClientLockPanel(onChanged: onChanged),
  );
}
