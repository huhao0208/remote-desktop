import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/client_lock.dart';
import '../core/lock_service.dart';
import '../core/theme.dart';

/// 客户端锁的解锁界面（官方 B6.3）。
///
/// 设计要点：
/// 1. **不透明**盖住整屏，不能透出底下的设备列表（那等于没锁）；
/// 2. 失败原因就地显示，不用 SnackBar（SnackBar 几秒就消失，用户会漏看）；
/// 3. 冷却期把输入框和按钮一起禁用并显示倒计时，否则用户会一直狂按；
/// 4. 短信验证码是「忘记密码」的出口，需要服务端支持，没配时明确说明。
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'lock-password');

  String? _error;
  bool _busy = false;

  /// 冷却倒计时：每秒刷新一次显示，冷却结束自动恢复可输入。
  Timer? _cooldownTicker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
    _syncCooldown();
  }

  @override
  void dispose() {
    _cooldownTicker?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// `cooldownRemainingMs > 0` 时启动秒级刷新，归零后停表。
  void _syncCooldown() {
    final int remaining = LockService.instance.client.cooldownRemainingMs;
    if (remaining <= 0) {
      _cooldownTicker?.cancel();
      _cooldownTicker = null;
      return;
    }
    _cooldownTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (LockService.instance.client.cooldownRemainingMs <= 0) {
        _cooldownTicker?.cancel();
        _cooldownTicker = null;
      }
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    final String password = _controller.text;
    if (password.isEmpty) {
      setState(() => _error = '请输入安全密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final bool ok = await LockService.instance.unlock(password);
    if (!mounted) return;
    if (ok) {
      // 解锁成功后这个 widget 会被父级移除，不需要额外跳转
      _controller.clear();
      return;
    }
    setState(() {
      _busy = false;
      _error = LockService.instance.client.lastError ?? '密码错误';
    });
    _syncCooldown();
    _controller.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final ClientLock lock = LockService.instance.client;
    final int cooldown = lock.cooldownRemainingMs;
    final bool blocked = cooldown > 0;
    final int attemptsLeft = lock.attemptsLeft;

    return Material(
      // 必须不透明：透出底下的设备列表等于没锁
      color: AppColors.bg,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Icon(Icons.lock_outline, size: 40, color: AppColors.accent),
                const SizedBox(height: AppSpace.md),
                const Text(
                  '已锁定',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '输入安全密码继续使用',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: AppColors.muted),
                ),
                const SizedBox(height: AppSpace.lg),
                TextField(
                  controller: _controller,
                  focusNode: _focus,
                  obscureText: true,
                  enabled: !blocked && !_busy,
                  maxLength: ClientLock.maxLength,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: '安全密码',
                    counterText: '',
                    errorText: _error,
                    prefixIcon: const Icon(Icons.password, size: 18),
                    border: const OutlineInputBorder(),
                    helperText: blocked
                        ? '尝试次数过多，请 ${(cooldown / 1000).ceil()} 秒后重试'
                        : (attemptsLeft < 5 ? '还剩 $attemptsLeft 次尝试机会' : null),
                    helperStyle: TextStyle(
                      color: blocked ? AppColors.danger : AppColors.muted,
                      fontSize: 11.5,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.md),
                SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: blocked || _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('解锁'),
                  ),
                ),
                const SizedBox(height: AppSpace.lg),
                TextButton(
                  onPressed: () => _showSmsHint(),
                  child: const Text('忘记密码？用短信验证码解锁'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 短信验证码通道需要服务端下发（`forgotPassword` / `getCode`）。
  ///
  /// 本地没有对应端点，这里如实说明而不是做一个假的「已发送」。
  void _showSmsHint() {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('短信验证码解锁'),
        content: const Text(
          '这条通道需要服务端下发验证码（官方是 forgotPassword → getCode → 60 秒重发）。'
          '当前自建服务端还没有这个端点，所以暂时只能用安全密码解锁。\n\n'
          '如果密码也忘了：清掉本机配置里的 client_lock_hash 可重置（会一并关闭三个自动锁定开关）。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
