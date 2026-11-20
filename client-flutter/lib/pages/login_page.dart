import 'package:material_ui/material_ui.dart';

import '../core/api_client.dart';
import '../core/device_identity.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import 'device_list_page.dart';

/// 登录页：手机号登录，登录请求顺带注册本机设备。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _mobile = TextEditingController();
  late final TextEditingController _server = TextEditingController(text: Settings.serverBase);
  bool _loading = false;
  bool _showServer = false;
  String? _error;

  @override
  void dispose() {
    _mobile.dispose();
    _server.dispose();
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
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildBrand(),
                const SizedBox(height: 32),
                TextField(
                  controller: _mobile,
                  enabled: !_loading,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    if (!_loading) _login();
                  },
                  decoration: const InputDecoration(
                    hintText: '手机号',
                    prefixIcon: Icon(Icons.phone_iphone, color: AppColors.muted, size: 20),
                  ),
                ),
                const SizedBox(height: 12),
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 180),
                  crossFadeState: _showServer ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                  firstChild: const SizedBox(width: double.infinity),
                  secondChild: Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    child: TextField(
                      controller: _server,
                      enabled: !_loading,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: '服务端地址',
                        hintText: 'https://host:8444',
                        prefixIcon: Icon(Icons.dns_outlined, color: AppColors.muted, size: 20),
                      ),
                    ),
                  ),
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 14),
                  _ErrorBanner(message: _error!),
                ],
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _loading ? null : _login,
                  child: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('登录'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _loading
                      ? null
                      : () => setState(() => _showServer = !_showServer),
                  child: Text(_showServer ? '收起服务器设置' : '服务器设置'),
                ),
                const SizedBox(height: 28),
                Text(
                  '本机：${DeviceIdentity.name}\n设备标识：${DeviceIdentity.platform} · ${DeviceIdentity.uuid}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted, fontSize: 11.5, height: 1.6),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBrand() {
    return Column(
      children: <Widget>[
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.desktop_windows_outlined, color: Colors.white, size: 30),
        ),
        const SizedBox(height: 18),
        const Text(
          'UU Remote',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: 0.4),
        ),
        const SizedBox(height: 6),
        const Text(
          '远程桌面控制端',
          style: TextStyle(color: AppColors.muted, fontSize: 13),
        ),
      ],
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
        borderRadius: BorderRadius.circular(10),
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