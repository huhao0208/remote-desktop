import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/agent_host.dart';
import '../core/api_client.dart';
import '../core/device_identity.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../widgets/ui_kit.dart';
import 'device_list_page.dart';

/// 登录页：手机号登录，登录请求顺带注册本机设备。
///
/// 布局策略：宽屏（桌面/平板）居中卡片 + 背景微光；窄屏（手机）铺满、去卡片边框，
/// 让键盘弹出时可用高度最大化。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _mobile = TextEditingController(text: Settings.mobile);
  late final TextEditingController _server = TextEditingController(text: Settings.serverBase);
  final FocusNode _mobileFocus = FocusNode(debugLabel: 'login-mobile');

  bool _loading = false;
  bool _showServer = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 手机号为空时才自动聚焦；有记忆值说明是老用户，焦点放到输入框末尾即可
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _mobileFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _mobile.dispose();
    _server.dispose();
    _mobileFocus.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final String mobile = _mobile.text.trim();
    if (mobile.replaceAll(RegExp(r'\D'), '').length < 5) {
      setState(() => _error = '请输入正确的手机号');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    await Settings.setServerBase(_server.text);
    final ApiClient api = ApiClient(baseUrl: Settings.serverBase);
    try {
      final result = await api.loginByMobile(mobile);
      await Settings.saveSession(
        token: result.token,
        uid: result.uid,
        mobile: result.mobile.isEmpty ? mobile : result.mobile,
        nickname: result.nickname,
        deviceId: result.deviceId,
      );
      if (!mounted) return;
      // 登录成功 → 拉起内置被控端（桌面端），让本机立即可被控制
      unawaited(AgentHost.instance.syncSession());
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const DeviceListPage()),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '登录失败：$e');
    } finally {
      api.close();
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool wide = Breakpoints.isWide(context);
    final Widget form = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _brand(),
        const SizedBox(height: AppSpace.xl),
        _mobileField(),
        const SizedBox(height: AppSpace.md),
        _serverSection(),
        if (_error != null) ...<Widget>[
          const SizedBox(height: AppSpace.md),
          _ErrorBanner(message: _error!),
        ],
        const SizedBox(height: AppSpace.lg),
        _submitButton(),
        const SizedBox(height: AppSpace.sm),
        TextButton(
          onPressed: _loading ? null : () => setState(() => _showServer = !_showServer),
          child: Text(
            _showServer ? '收起服务器设置' : '服务器设置',
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
      ],
    );

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(color: AppColors.bg),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: wide ? AppSpace.xl : AppSpace.lg,
                vertical: AppSpace.xxl,
              ),
              child: wide
                  ? Container(
                      width: 420,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.xl,
                        vertical: AppSpace.xl + 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surface.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: AppColors.border),
                        boxShadow: AppShadows.card,
                      ),
                      child: form,
                    )
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: form,
                    ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.only(bottom: AppSpace.md),
        child: _footer(),
      ),
    );
  }

  Widget _brand() {
    return Column(
      children: <Widget>[
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[AppColors.accentHover, AppColors.accentDim],
            ),
            borderRadius: BorderRadius.circular(18),
            boxShadow: <BoxShadow>[
              BoxShadow(color: AppColors.accent.withValues(alpha: 0.28), blurRadius: 20, offset: const Offset(0, 8)),
            ],
          ),
          child: const Icon(Icons.desktop_windows_outlined, color: Colors.white, size: 30),
        ),
        const SizedBox(height: AppSpace.lg),
        Text('UU Remote', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 6),
        const Text(
          '远程桌面控制端 · 打洞直连优先',
          style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.5),
        ),
      ],
    );
  }

  Widget _mobileField() {
    return TextField(
      controller: _mobile,
      focusNode: _mobileFocus,
      enabled: !_loading,
      keyboardType: TextInputType.phone,
      textInputAction: TextInputAction.done,
      autofillHints: const <String>[AutofillHints.telephoneNumber],
      style: const TextStyle(fontSize: 16, letterSpacing: 0.6),
      onSubmitted: (_) {
        if (!_loading) _login();
      },
      decoration: InputDecoration(
        hintText: '手机号',
        prefixIcon: const Icon(Icons.phone_iphone, color: AppColors.muted, size: 20),
        suffixIcon: _mobile.text.isEmpty
            ? null
            : IconButton(
                tooltip: '清空',
                icon: const Icon(Icons.close, size: 16, color: AppColors.faint),
                onPressed: _loading ? null : () => setState(_mobile.clear),
              ),
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _serverSection() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: !_showServer
          ? Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Text(
                  '服务器 ${Settings.serverBase}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: AppColors.faint),
                ),
              ),
            )
          : Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs),
              child: TextField(
                controller: _server,
                enabled: !_loading,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '服务端地址',
                  hintText: 'https://host:8444',
                  prefixIcon: Icon(Icons.dns_outlined, color: AppColors.muted, size: 20),
                  helperText: '留空则用默认地址；自建服务端填 IP 或域名',
                ),
              ),
            ),
    );
  }

  Widget _submitButton() {
    return ElevatedButton(
      onPressed: _loading ? null : _login,
      child: _loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : const Text('登录'),
    );
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: <Widget>[
              Pill(text: DeviceIdentity.platform, icon: Icons.memory, color: AppColors.faint),
              Pill(text: DeviceIdentity.name, icon: Icons.badge_outlined, color: AppColors.faint),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            '设备标识 ${DeviceIdentity.uuid.substring(0, DeviceIdentity.uuid.length.clamp(0, 8))}',
            style: const TextStyle(color: AppColors.faint, fontSize: 10.5),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.12),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.error_outline, color: AppColors.danger, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Color(0xFFFFB4AB), fontSize: 12.5, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}