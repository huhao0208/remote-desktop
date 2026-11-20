import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import 'login_page.dart';
import 'remote_page.dart';

/// 设备列表：显示名称/平台/在线/本机/可控，点击可控设备进远控页。
class DeviceListPage extends StatefulWidget {
  const DeviceListPage({super.key});

  @override
  State<DeviceListPage> createState() => _DeviceListPageState();
}

class _DeviceListPageState extends State<DeviceListPage> {
  late ApiClient _api;
  List<DeviceInfo> _devices = const <DeviceInfo>[];
  bool _loading = true;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(baseUrl: Settings.serverBase);
    _load();
    // 设备在线状态靠服务端 WS 连接维护，这里轻量轮询即可
    _timer = Timer.periodic(const Duration(seconds: 12), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _api.close();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final List<DeviceInfo> list = await _api.listDevices(
        token: Settings.token,
        selfDeviceId: Settings.deviceId,
      );
      if (!mounted) return;
      setState(() {
        _devices = list;
        _error = null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        await _logout(ask: false);
        return;
      }
      if (silent) return; // 轮询失败保留旧列表，避免界面闪错
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || silent) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _logout({bool ask = true}) async {
    if (ask) {
      final bool? ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('退出登录'),
          content: const Text('退出后需重新输入手机号登录，设备记录会保留。'),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('退出', style: TextStyle(color: AppColors.danger)),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await Settings.clearSession();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      (Route<dynamic> route) => false,
    );
  }

  Future<void> _editServer() async {
    final TextEditingController controller = TextEditingController(text: Settings.serverBase);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('服务端地址'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://host:8444'),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    await Settings.setServerBase(controller.text);
    _api.close();
    _api = ApiClient(baseUrl: Settings.serverBase);
    await _load();
  }

  Future<void> _open(DeviceInfo device) async {
    if (device.isSelf) {
      _toast('这是本机，不能控制自己');
      return;
    }
    if (!device.online) {
      _toast('设备离线：先在电脑上启动被控端 Agent');
      return;
    }
    if (!device.controllable) {
      _toast('${device.platformLabel} 设备暂不支持远控');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => RemotePage(device: device)),
    );
    if (mounted) await _load(silent: true);
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('我的设备', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            Text(
              Settings.nickname.isEmpty ? Settings.mobile : '${Settings.nickname} · ${Settings.mobile}',
              style: const TextStyle(fontSize: 11.5, color: AppColors.muted, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            onPressed: () => _load(),
            icon: const Icon(Icons.refresh, size: 21),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            color: AppColors.surfaceAlt,
            onSelected: (String value) {
              if (value == 'server') _editServer();
              if (value == 'logout') _logout();
            },
            itemBuilder: (BuildContext ctx) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'server', child: Text('服务端地址')),
              PopupMenuItem<String>(value: 'logout', child: Text('退出登录')),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _devices.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    }
    if (_error != null && _devices.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.cloud_off, color: AppColors.muted, size: 40),
              const SizedBox(height: 14),
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: () => _load(), child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_devices.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.devices_other, color: AppColors.muted, size: 42),
              const SizedBox(height: 14),
              const Text('这个账号下还没有设备', style: TextStyle(fontSize: 14)),
              const SizedBox(height: 6),
              const Text(
                '在电脑上启动被控端，用同一手机号登录后即可出现在这里',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 18),
              OutlinedButton(onPressed: () => _load(), child: const Text('刷新')),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        itemCount: _devices.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (BuildContext ctx, int i) => _tile(_devices[i]),
      ),
    );
  }

  Widget _tile(DeviceInfo device) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _open(device),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_iconFor(device), color: AppColors.muted, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            device.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (device.isSelf) ...<Widget>[
                          const SizedBox(width: 8),
                          _tag('本机', AppColors.muted),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${device.platformLabel} · ${device.online ? '在线' : _lastSeenText(device.lastSeen)}',
                      style: const TextStyle(fontSize: 12, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              _statusChip(device),
              if (device.controllable) ...<Widget>[
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right, color: AppColors.muted, size: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusChip(DeviceInfo device) {
    if (!device.online) {
      return _tag('离线', AppColors.muted);
    }
    if (device.controllable) {
      return _tag('可远控', AppColors.accent);
    }
    return _tag('在线', AppColors.warn);
  }

  Widget _tag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }

  IconData _iconFor(DeviceInfo device) {
    switch (device.platform) {
      case 'android':
      case 'ios':
      case 'mobile':
        return Icons.smartphone;
      case 'android_tv':
        return Icons.tv;
      default:
        return Icons.desktop_windows_outlined;
    }
  }

  String _lastSeenText(int ms) {
    if (ms <= 0) return '从未上线';
    final int delta = DateTime.now().millisecondsSinceEpoch - ms;
    if (delta < 60000) return '刚刚在线';
    if (delta < 3600000) return '${delta ~/ 60000} 分钟前在线';
    if (delta < 86400000) return '${delta ~/ 3600000} 小时前在线';
    return '${delta ~/ 86400000} 天前在线';
  }
}