import 'dart:async';

import 'package:flutter/services.dart';

import 'package:material_ui/material_ui.dart';

import '../core/agent_host.dart';
import '../core/api_client.dart';
import '../core/lock_service.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../core/updater.dart';
import '../core/version.g.dart';
import '../widgets/client_lock_panel.dart';
import '../widgets/ui_kit.dart';
import '../widgets/update_dialog.dart';
import 'login_page.dart';
import 'remote_page.dart';

/// 设备页（官方布局）：大标题 + 筛选胶囊 + 在线/离线分组卡片 + 底部三 Tab。
class DeviceListPage extends StatefulWidget {
  const DeviceListPage({super.key});

  @override
  State<DeviceListPage> createState() => _DeviceListPageState();
}

class _DeviceListPageState extends State<DeviceListPage> {
  final ApiClient _api = ApiClient(baseUrl: Settings.serverBase);
  final TextEditingController _search = TextEditingController();

  List<DeviceInfo> _devices = <DeviceInfo>[];
  String _query = '';
  bool _loading = true;
  String? _error;
  int _tab = 0;

  /// 在线分组默认展开，离线默认也展开（与官方稿一致）
  bool _onlineExpanded = true;
  bool _offlineExpanded = true;

  /// 全部 / 仅在线
  bool _onlyOnline = false;

  Timer? _poll;

  /// 上一次后台检查到的更新结果（null = 还没检查过）。
  UpdateCheckResult? _update;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _load(silent: true));
    unawaited(_silentUpdateCheck());
  }

  /// 启动后延迟 3s 静默查一次更新：24h 节流，命中缓存不发请求。
  ///
  /// 只查不下载——远程桌面客户端在用户远控时被静默替换会直接断链，
  /// 升级动作必须由用户在「我的 → 检查更新」里点。
  Future<void> _silentUpdateCheck() async {
    if (!Settings.updateAutoCheck) return;
    await Future<void>.delayed(const Duration(seconds: 3));
    final UpdateCheckResult r = await Updater.check();
    if (!mounted) return;
    setState(() => _update = r);
  }

  Future<void> _openUpdateDialog() async {
    await showUpdateDialog(context, initial: _update);
    if (!mounted) return;
    // 关掉对话框后刷新角标（用户可能刚点了「跳过此版本」）
    final UpdateCheckResult r = await Updater.check();
    if (mounted) setState(() => _update = r);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _api.close();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = _devices.isEmpty);
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<DeviceInfo> get _filtered {
    final String q = _query.trim().toLowerCase();
    return _devices.where((DeviceInfo d) {
      if (_onlyOnline && !d.online) return false;
      if (q.isEmpty) return true;
      return d.name.toLowerCase().contains(q) || d.platformLabel.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _open(DeviceInfo device) async {
    if (!device.online || !device.controllable) {
      _toast('该设备当前离线或不可控');
      return;
    }
    // 建房间交给 RemotePage 自己做（它要边连边显示状态），这里只负责跳转。
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => RemotePage(device: device)),
    );
    _load(silent: true);
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _tab,
          children: <Widget>[
            _devicesTab(),
            _AssistTab(onDone: () => setState(() => _tab = 0)),
            _ProfileTab(onLoggedOut: _logout, update: _update, onCheckUpdate: _openUpdateDialog),
          ],
        ),
      ),
      bottomNavigationBar: _BottomBar(
        index: _tab,
        hasUpdate: _update?.hasUpdate ?? false,
        onTap: (int i) => setState(() => _tab = i),
      ),
    );
  }

  Widget _devicesTab() {
    final List<DeviceInfo> list = _filtered;
    final List<DeviceInfo> online = list.where((DeviceInfo d) => d.online).toList();
    final List<DeviceInfo> offline = list.where((DeviceInfo d) => !d.online).toList();

    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: <Widget>[
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _header(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: AppSpace.sm, bottom: AppSpace.md),
                            child: _errorBanner(),
                          ),
                        if (_loading)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: AppSpace.xxl),
                            child: LoadingView(text: '正在获取设备列表'),
                          )
                        else if (list.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: AppSpace.xxl),
                            child: EmptyState(
                              icon: Icons.devices_other_outlined,
                              title: _query.isEmpty && !_onlyOnline ? '还没有可控设备' : '没有匹配的设备',
                              message: _query.isEmpty && !_onlyOnline
                                  ? '在要控制的电脑上安装并登录同一账号，设备会自动出现在这里'
                                  : '换个关键词，或把筛选切回「全部设备」',
                              action: _query.isEmpty && !_onlyOnline
                                  ? null
                                  : TextButton(
                                      onPressed: () => setState(() {
                                        _query = '';
                                        _search.clear();
                                        _onlyOnline = false;
                                      }),
                                      child: const Text('清除筛选'),
                                    ),
                            ),
                          )
                        else ...<Widget>[
                          if (online.isNotEmpty) ...<Widget>[
                            const SizedBox(height: AppSpace.lg),
                            GroupHeader(
                              text: '在线设备',
                              count: online.length,
                              expanded: _onlineExpanded,
                              onTap: () => setState(() => _onlineExpanded = !_onlineExpanded),
                            ),
                            AnimatedSize(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
                              alignment: Alignment.topCenter,
                              child: _onlineExpanded
                                  ? Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: online
                                          .map((DeviceInfo d) => Padding(
                                                padding: const EdgeInsets.only(bottom: 10),
                                                child: _deviceCard(d),
                                              ))
                                          .toList(),
                                    )
                                  : const SizedBox(width: double.infinity, height: 0),
                            ),
                          ],
                          if (offline.isNotEmpty) ...<Widget>[
                            const SizedBox(height: AppSpace.xl),
                            GroupHeader(
                              text: '离线设备',
                              count: offline.length,
                              expanded: _offlineExpanded,
                              onTap: () => setState(() => _offlineExpanded = !_offlineExpanded),
                            ),
                            AnimatedSize(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
                              alignment: Alignment.topCenter,
                              child: _offlineExpanded
                                  ? Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: offline
                                          .map((DeviceInfo d) => Padding(
                                                padding: const EdgeInsets.only(bottom: 10),
                                                child: _deviceCard(d),
                                              ))
                                          .toList(),
                                    )
                                  : const SizedBox(width: double.infinity, height: 0),
                            ),
                          ],
                          const SizedBox(height: AppSpace.xl),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 大标题 + 右侧筛选胶囊（官方稿的位置）
  Widget _header() {
    final bool wide = Breakpoints.isWide(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(AppSpace.xl, wide ? AppSpace.xl : AppSpace.lg, AppSpace.xl, AppSpace.xs),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '可控设备',
              style: TextStyle(
                fontSize: wide ? 30 : 24,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
                height: 1.2,
              ),
            ),
          ),
          PopupMenuButton<bool>(
            tooltip: '筛选设备',
            initialValue: _onlyOnline,
            onSelected: (bool v) => setState(() => _onlyOnline = v),
            itemBuilder: (BuildContext context) => <PopupMenuEntry<bool>>[
              const PopupMenuItem<bool>(value: false, child: Text('全部设备')),
              const PopupMenuItem<bool>(value: true, child: Text('仅在线设备')),
            ],
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFE9ECEF),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.devices_outlined, size: 15, color: Color(0xFF2B2D30)),
                  const SizedBox(width: 6),
                  Text(
                    _onlyOnline ? '仅在线' : '全部设备',
                    style: const TextStyle(fontSize: 13, color: Color(0xFF2B2D30)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner() {
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.error_outline, size: 16, color: AppColors.danger),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              _error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: AppColors.danger, height: 1.4),
            ),
          ),
          TextButton(onPressed: _load, child: const Text('重试')),
        ],
      ),
    );
  }

  /// 设备卡：左缩略图 + 名称/平台图标 + 右箭头；在线黑字，离线灰化。
  Widget _deviceCard(DeviceInfo device) {
    final bool on = device.online;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double thumbW = 96;
        return AppCard(
          padding: EdgeInsets.zero,
          onTap: () => _open(device),
          child: SizedBox(
            height: 82,
            child: Row(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 0, 10),
                  child: DeviceThumb(
                    width: thumbW,
                    height: 62,
                    icon: _platformIcon(device),
                    online: on,
                    radius: BorderRadius.circular(AppRadius.sm),
                    statusLabel: on ? '在线' : null,
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(11, 12, AppSpace.sm, 12),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          device.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: on ? AppColors.text : const Color(0xFF6F747A),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: <Widget>[
                            _platformBadge(device),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                on
                                    ? device.platformLabel
                                    : (device.lastSeen <= 0
                                        ? '${device.platformLabel} · 未上线'
                                        : '${device.platformLabel} · 最后在线 ${_lastSeenText(device.lastSeen)}'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: on ? AppColors.muted : const Color(0xFF8A9099),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Icon(Icons.chevron_right, size: 18, color: on ? AppColors.faint : const Color(0xFFCDD2D8)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 平台小圆角方块：在线蓝底，离线灰底（官方稿的做法）
  Widget _platformBadge(DeviceInfo device) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: device.online ? AppColors.accent : const Color(0xFFA9B1B9),
        borderRadius: BorderRadius.circular(4.5),
      ),
      child: Icon(_platformIcon(device), size: 10, color: Colors.white),
    );
  }

  IconData _platformIcon(DeviceInfo device) {
    // platformLabel 是中文展示名，英文平台串在 platform / name 里，一起判
    final String p = '${device.platformLabel} ${device.platform} ${device.name}'.toLowerCase();
    // 顺序要紧：'Android TV' 里也含 android，电视必须先判
    if (p.contains('tv') || p.contains('电视')) return Icons.tv_rounded;
    if (p.contains('平板') || p.contains('pad')) return Icons.tablet_mac;
    if (p.contains('手机') || p.contains('phone')) return Icons.smartphone;
    if (p.contains('mac') || p.contains('笔记本')) return Icons.laptop_mac;
    if (p.contains('android') || p.contains('ios')) return Icons.smartphone;
    if (p.contains('linux')) return Icons.computer;
    return Icons.desktop_windows;
  }

  String _lastSeenText(int ts) {
    if (ts <= 0) return '离线';
    // 服务端给的是秒级时间戳
    final DateTime lastSeen = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final Duration d = DateTime.now().difference(lastSeen);
    if (d.isNegative || d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    return '${lastSeen.month}月${lastSeen.day}日';
  }

  Future<void> _logout() async {
    // 先杀被控端再清会话：token 失效后 Agent 会一直重试登录，日志很吵
    await AgentHost.instance.stop();
    await Settings.clearSession();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      (Route<dynamic> route) => false,
    );
  }
}

/// 远程协助：输入对方设备 ID 直接发起（服务端 joinRoom 会校验设备是否存在、是否在线）。
class _AssistTab extends StatefulWidget {
  const _AssistTab({required this.onDone});

  final VoidCallback onDone;

  @override
  State<_AssistTab> createState() => _AssistTabState();
}

class _AssistTabState extends State<_AssistTab> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _start() {
    final String id = _ctrl.text.trim();
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先填写设备 ID')));
      return;
    }
    final DeviceInfo target = DeviceInfo(
      deviceId: id,
      name: '远程设备',
      platform: 'unknown',
      online: true,
      isSelf: false,
      controllable: true,
      lastSeen: 0,
    );
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => RemotePage(device: target)))
        .then((_) => widget.onDone());
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpace.xl),
      children: <Widget>[
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Padding(
                  padding: EdgeInsets.only(top: AppSpace.md, bottom: AppSpace.lg),
                  child: Text(
                    '远程协助',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: AppColors.text),
                  ),
                ),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const Text(
                        '输入对方设备 ID',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.text),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      const Text(
                        '对方设备需在线并登录同一账号，连接由服务端建房间后直连传输。',
                        style: TextStyle(fontSize: 12.5, color: AppColors.muted, height: 1.5),
                      ),
                      const SizedBox(height: AppSpace.md),
                      TextField(
                        controller: _ctrl,
                        onSubmitted: (_) => _start(),
                        decoration: const InputDecoration(hintText: '例如 6f1c2a90-...'),
                      ),
                      const SizedBox(height: AppSpace.lg),
                      ElevatedButton.icon(
                        onPressed: _start,
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        label: const Text('发起远控'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 我的：账号信息、服务器地址（可改）、本机设备 ID、退出登录。全部读真实本地状态。
class _ProfileTab extends StatefulWidget {
  const _ProfileTab({required this.onLoggedOut, this.update, this.onCheckUpdate});

  final Future<void> Function() onLoggedOut;
  final UpdateCheckResult? update;
  final Future<void> Function()? onCheckUpdate;

  @override
  State<_ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<_ProfileTab> {
  @override
  void initState() {
    super.initState();
    // 被控端进程状态可能在别处变化（登录/自愈），这里跟着刷新
    AgentHost.instance.state.addListener(_onAgentChanged);
    AgentHost.instance.detail.addListener(_onAgentChanged);
  }

  @override
  void dispose() {
    AgentHost.instance.state.removeListener(_onAgentChanged);
    AgentHost.instance.detail.removeListener(_onAgentChanged);
    super.dispose();
  }

  void _onAgentChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final String nickname = Settings.nickname.isEmpty ? '未设置昵称' : Settings.nickname;
    final String mobile = Settings.mobile.isEmpty ? '—' : Settings.mobile;
    return ListView(
      padding: const EdgeInsets.all(AppSpace.xl),
      children: <Widget>[
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Padding(
                  padding: EdgeInsets.only(top: AppSpace.md, bottom: AppSpace.lg),
                  child: Text(
                    '我的',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: AppColors.text),
                  ),
                ),
                AppCard(
                  child: Row(
                    children: <Widget>[
                      Container(
                        width: 46,
                        height: 46,
                        decoration: const BoxDecoration(color: AppColors.accentDim, shape: BoxShape.circle),
                        child: const Icon(Icons.person_outline, color: AppColors.accent, size: 24),
                      ),
                      const SizedBox(width: AppSpace.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(nickname, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.text)),
                            const SizedBox(height: 2),
                            Text(mobile, style: const TextStyle(fontSize: 12.5, color: AppColors.muted)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpace.lg),
                AppCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: <Widget>[
                      _row(
                        context,
                        icon: Icons.dns_outlined,
                        label: '服务器地址',
                        value: Settings.serverBase,
                        onTap: () => _editServer(context),
                      ),
                      const Divider(height: 1),
                      _row(
                        context,
                        icon: Icons.fingerprint,
                        label: '本机设备 ID',
                        value: Settings.deviceId.isEmpty ? '—' : Settings.deviceId,
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: Settings.deviceId));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('设备 ID 已复制')));
                        },
                      ),
                      const Divider(height: 1),
                      _row(
                        context,
                        icon: Icons.system_update_alt,
                        label: '检查更新',
                        value: _updateValue(),
                        highlight: widget.update?.hasUpdate ?? false,
                        onTap: widget.onCheckUpdate == null ? null : () => widget.onCheckUpdate!(),
                      ),
                      const Divider(height: 1),
                      _row(
                        context,
                        icon: Icons.lock_outline,
                        // 官方的「安全锁定」就是客户端锁：设密码 + 三种自动锁定
                        label: '安全锁定',
                        value: LockService.instance.client.hasPassword ? '已设置密码' : '未设置',
                        highlight: LockService.instance.client.hasPassword,
                        onTap: () => showClientLockPanel(
                          context,
                          onChanged: () {
                            if (mounted) setState(() {});
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpace.lg),
                _agentCard(),
                const SizedBox(height: AppSpace.xl),
                TextButton(
                  onPressed: () => widget.onLoggedOut(),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    minimumSize: const Size(0, 46),
                    backgroundColor: AppColors.surface,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: const Text('退出登录', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 内置被控端开关：与 `AgentHost` 进程状态联动（关闭即杀进程，打开即拉起）。
  Widget _agentCard() {
    final AgentHost host = AgentHost.instance;
    final AgentHostState state = host.state.value;
    final bool desktop = host.isDesktopPlatform;
    final bool allowed = Settings.allowBeControlled;
    final String? detail = host.detail.value;
    final bool needsRepair =
        state == AgentHostState.missing || state == AgentHostState.failed;

    String subtitle;
    Color color = AppColors.muted;
    if (!desktop) {
      subtitle = AgentHost.describe(AgentHostState.unsupported);
    } else if (!allowed) {
      subtitle = AgentHost.describe(AgentHostState.stopped);
    } else {
      subtitle = AgentHost.describe(state);
      if (detail != null && detail.isNotEmpty && state != AgentHostState.running) {
        subtitle = '$subtitle · $detail';
      }
      if (state == AgentHostState.running) color = AppColors.accent;
      if (state == AgentHostState.restarting || needsRepair) color = AppColors.warn;
    }

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.sensors, size: 18, color: desktop ? AppColors.muted : AppColors.faint),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '允许其他设备控制本机',
                      style: TextStyle(
                        fontSize: 14,
                        color: desktop ? AppColors.text : AppColors.faint,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, height: 1.4, color: color),
                    ),
                  ],
                ),
              ),
              Switch(
                value: allowed && desktop,
                onChanged: desktop ? _toggleAgent : null,
              ),
            ],
          ),
          if (needsRepair) ...<Widget>[
            const SizedBox(height: AppSpace.sm),
            Text(
              '把打包好的 uu-agent 放到应用资源目录后重试；开发时可用 '
              'UU_AGENT_BIN=/path/to/uu-agent 启动。',
              style: const TextStyle(fontSize: 11, color: AppColors.faint, height: 1.4),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => AgentHost.instance.syncSession(force: true),
                child: const Text('重试启动'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _toggleAgent(bool value) async {
    await Settings.setAllowBeControlled(value);
    if (mounted) setState(() {});
    await AgentHost.instance.syncSession(force: true);
    if (!mounted) return;
    if (value && AgentHost.instance.state.value == AgentHostState.missing) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('被控端未随包分发，本机暂时无法被控制')),
      );
    }
  }

  Widget _row(BuildContext context, {required IconData icon, required String label, required String value, VoidCallback? onTap, bool highlight = false}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: 15),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: AppColors.muted),
            const SizedBox(width: AppSpace.md),
            Text(label, style: const TextStyle(fontSize: 14, color: AppColors.text)),
            const Spacer(),
            if (highlight) ...<Widget>[
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 13,
                  color: highlight ? AppColors.accent : AppColors.muted,
                  fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, size: 18, color: AppColors.faint),
          ],
        ),
      ),
    );
  }

  /// 「检查更新」右侧文案：把版本号和最新检查结果合成一行。
  String _updateValue() {
    final UpdateCheckResult? u = widget.update;
    if (u == null) return 'v$kAppVersion';
    if (u.hasUpdate) return 'v${u.info?.version ?? ''} 可升级';
    if (u.status == UpdateStatus.skipped) return 'v$kAppVersion · 已跳过新版';
    if (u.status == UpdateStatus.failed) return 'v$kAppVersion · 检查失败';
    return 'v$kAppVersion · 已是最新';
  }

  Future<void> _editServer(BuildContext context) async {
    final TextEditingController ctrl = TextEditingController(text: Settings.serverBase);
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('服务器地址'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'https://host:8443'),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await Settings.setServerBase(result);
      // 被控端把 --server 当启动参数，换了地址必须重起才会连新服务器
      unawaited(AgentHost.instance.syncSession(force: true));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存，重新登录后生效')));
      }
    }
  }
}

/// 底部三 Tab：白底 + 细分割线，选中蓝、未选中灰，只变颜色不加背景块。
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onTap, this.hasUpdate = false});

  final int index;
  final ValueChanged<int> onTap;

  /// 「我的」上挂个红点：有新版本但用户还没去看。
  final bool hasUpdate;

  static const List<(IconData, IconData, String)> _items = <(IconData, IconData, String)>[
    (Icons.devices_outlined, Icons.devices, '我的设备'),
    (Icons.support_agent_outlined, Icons.support_agent, '远程协助'),
    (Icons.person_outline, Icons.person, '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFFCFDFE),
        border: Border(top: BorderSide(color: Color(0xFFE3E6EA))),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: List<Widget>.generate(_items.length, (int i) {
              final bool on = i == index;
              final Color color = on ? AppColors.accent : const Color(0xFF7F8389);
              return Expanded(
                child: InkWell(
                  onTap: () => onTap(i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Stack(
                        clipBehavior: Clip.none,
                        children: <Widget>[
                          Icon(on ? _items[i].$2 : _items[i].$1, size: 22, color: color),
                          if (hasUpdate && i == 2)
                            Positioned(
                              right: -2,
                              top: -1,
                              child: Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: AppColors.danger,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: const Color(0xFFFCFDFE), width: 1),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _items[i].$3,
                        style: TextStyle(fontSize: 11.5, color: color, fontWeight: on ? FontWeight.w600 : FontWeight.w400),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}