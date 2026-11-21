import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/clipboard_sync.dart';
import '../core/connect_stage.dart';
import '../core/input_events.dart';
import '../core/mini_window.dart';
import '../core/models.dart';
import '../core/reconnect_policy.dart';
import '../core/security.dart';
import '../core/settings.dart';
import '../core/shortcuts.dart';
import '../core/theme.dart';
import '../core/version.g.dart';
import '../core/view_mode.dart';
import '../media/jpeg_transport.dart';
import '../media/media_factory.dart';
import '../media/media_transport.dart';
import '../media/webrtc_transport.dart';
import '../signaling/signaling_client.dart';
import '../widgets/annotation_layer.dart';
import '../widgets/mini_window_panel.dart';
import '../widgets/quality_panel.dart';
import '../widgets/power_panel.dart';
import '../widgets/remote_info_panel.dart';
import '../widgets/security_panel.dart';
import '../widgets/shortcuts_panel.dart';
import '../widgets/ui_kit.dart';
import '../widgets/view_toolbar.dart';

/// 远控页：加入房间 → 连信令 → 等 `agent.hello` → 渲染画面 + 转发输入。
///
/// UI 分三层：
/// 1. 顶栏：设备名 + 连接状态（细，不抢画面）；
/// 2. 舞台：画面 + 中断/等待浮层；
/// 3. 底部工具栏：毛玻璃浮层，全屏时自动隐藏，鼠标移到底部再出现。
class RemotePage extends StatefulWidget {
  const RemotePage({required this.device, super.key});

  final DeviceInfo device;

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> {
  late final ApiClient _api;
  SignalingClient? _signaling;
  MediaTransport? _transport;
  RoomConfig? _room;
  AgentHello? _hello;

  StreamSubscription<Map<String, dynamic>>? _msgSub;
  StreamSubscription<FramePacket>? _frameSub;
  ValueListenable<TransportStats>? _statsListenable;
  Timer? _ticker;
  Timer? _chromeTimer;

  /// 画质面板连续调整（拖码率滑块）时的下发防抖：只发最后一拍。
  Timer? _qualityDebounce;

  /// 剪贴板双向同步（协议 v2 §7）：去重/护栏/平台读写都在这里，
  /// 页面只负责把 `{p:"clip",dir:"down"}` 喂进来、把上行文本发出去。
  final ClipboardSync _clip = ClipboardSync();

  /// 自动重连退避：进度 1→2→4→8→15→30 秒封顶，8 次后停手转人工。
  final ReconnectPolicy _reconnectPolicy = ReconnectPolicy();

  /// 等待页的 7 阶段进度（对齐官方 init→…→success）。
  final ConnectProgress _progress = ConnectProgress();

  /// 自动重连的待触发定时器；非空表示「已排了一拍，正在等」。
  Timer? _reconnectTimer;

  /// 距离下一次自动重连还有几秒（给浮层显示，0 表示没在等）。
  int _reconnectIn = 0;

  bool _connecting = true;
  String? _error;

  /// `agent.error` 的可读说明，常驻在画面区顶部（清空条件：新 hello / 重连）。
  String? _agentError;
  bool _stalled = false;
  bool _applyingHello = false;

  bool _fullscreen = false;
  bool _chromeVisible = true;
  bool _keyboardLock = true;

  /// 网络状态浮层是否常显（官方把 netInfo 做成可选叠加层，不占顶栏）。
  /// 默认关：4 个数字常驻 46px 顶栏会把设备名挤没，需要时再从「更多」打开。
  bool _showHud = false;

  /// 22 项可配置快捷键（官方 B6.1）。落盘只存与出厂默认不同的项。
  late ShortcutMap _shortcuts;

  /// 观看模式：三态（操控/观看/批注）+ 缩放平移。
  ViewModeState _viewMode = const ViewModeState();

  /// 批注笔画板。会话内有效，不落盘（批注是临时标注）。
  final AnnotationBoard _annotations = AnnotationBoard();

  /// 小窗模式（官方 B5）。只在桌面端生效，移动端隐藏入口。
  MiniWindowState _mini = const MiniWindowState();

  /// 进入小窗前的窗口几何，退出时还原（否则用户会丢窗口位置）。
  Rect? _windowBeforeMini;

  /// 画面区当前尺寸。缩放要以视口中心为锚点，键盘操作拿不到鼠标位置，
  /// 只能靠这个值算 focal。build 时顺带更新，不触发重建。
  Size _stageSize = Size.zero;

  /// 观看模式拖拽的上一帧位置（视口坐标）。
  Offset? _panLast;

  /// 批注画笔颜色。
  Color _penColor = const Color(0xFFFF3B30);

  /// 当前画质参数（档位 + 分辨率/帧率/码率细项），见 `StreamPrefs`。
  StreamPrefs _quality = Settings.streamPrefs;

  /// 安全面板状态（防窥档 / 自动锁屏 / 被控静音）。
  ///
  /// 用 [ValueNotifier] 而不是普通字段：安全面板是独立路由，页面 setState
  /// 不会重建它，被控端返回「不支持」时面板要能当场显示出错并回退选中态。
  final ValueNotifier<SecurityState> _securityVN =
      ValueNotifier<SecurityState>(const SecurityState());

  SecurityState get _security => _securityVN.value;

  void _setSecurity(SecurityState next) {
    _securityVN.value = next;
    if (mounted) setState(() {});
  }

  /// 关机/重启倒计时（非空时画面顶部常驻撤销条）。
  PowerCountdown? _countdown;

  /// 是否已经收到过新协议的 `power.state`。老 Agent 只发 `shutdown.state`，
  /// 用它决定要不要走兼容分支——否则两条事件会把倒计时重复弹一遍。
  bool _powerStateSeen = false;
  int _fps = 0;
  int _framesInWindow = 0;
  Duration _latency = Duration.zero;
  DateTime? _lastFrameAt;

  /// WebRTC 的 getStats() 结果（JPEG 通路恒为空，HUD 走 [_fps]）。
  TransportStats _stats = const TransportStats();

  /// 音频（协议 v2 §1）：是否已收到远端轨、是否本地静音。
  bool _audioAvailable = false;
  bool _audioMuted = false;

  final FocusNode _focusNode = FocusNode(debugLabel: 'remote-keyboard');
  final Set<String> _heldMods = <String>{};

  Offset? _downAt;
  DateTime? _downTime;
  bool _dragged = false;
  bool _longPressFired = false;
  Timer? _longPress;
  Offset? _lastSent;
  DateTime _lastSentAt = DateTime.fromMillisecondsSinceEpoch(0);
  Size _screen = const Size(1920, 1080);

  /// 多屏（协议 v2 §3）：Agent 推的显示器列表 + 当前屏 id。
  /// 老 Agent 不发 `screens` → 列表为空，工具栏不显示切屏入口。
  List<ScreenInfo> _screens = const <ScreenInfo>[];
  int _screenId = 0;

  /// 连接信息面板用：最近 60 拍延时（≈1 分钟）与连接起点。
  final List<int> _latencyHistory = <int>[];
  DateTime? _connectedAt;

  bool get _isDesktop => !(Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    _api = ApiClient(baseUrl: Settings.serverBase);
    _quality = Settings.streamPrefs;
    _clip.enabled = Settings.clipboardSync;
    _shortcuts = ShortcutMap.fromJson(_jsonObject(Settings.shortcutsJson));
    _mini = MiniWindowState.fromJson(_jsonObject(Settings.miniWindowJson));
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    _connect();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
    // 首屏给 5 秒适应期再自动收起工具栏（比官方 2.2s 宽松：新用户要先看清按钮）
    if (_autoHideChrome) {
      _chromeTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _chromeVisible = false);
      });
    }
  }

  /// 释放被控端可能还按着的修饰键，避免对端「卡键」。
  ///
  /// 两个时机都要用：
  /// ① **窗口失焦**——按住 Shift 再 Cmd+Tab 切走，Focus 收不到那次 keyUp，
  ///    远端 Shift 会一直按着（再点一下别处才好），所以失焦必须兜一次；
  /// ② **页面销毁**——正常退出远控。
  /// 只补发 keyUp，不动本地 `_keyboardLock`（切回来还能继续用键盘）。
  void _releaseHeldMods() {
    if (_heldMods.isEmpty) return;
    final SignalingClient? signaling = _signaling;
    if (signaling != null && signaling.isOpen) {
      for (final String mod in _heldMods) {
        signaling.sendJson(InputEvent.keyUp(mod));
      }
    }
    _heldMods.clear();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _chromeTimer?.cancel();
    _qualityDebounce?.cancel();
    _longPress?.cancel();
    _reconnectTimer?.cancel();
    _msgSub?.cancel();
    _frameSub?.cancel();
    _releaseHeldMods();
    // 退出页面时若仍在全屏，恢复窗口，避免把整个 App 卡在全屏
    if (_fullscreen) _setFullscreen(false);
    _statsListenable?.removeListener(_onStats);
    _statsListenable = null;
    _transport?.dispose();
    _signaling?.close();
    _api.close();
    _focusNode.dispose();
    _securityVN.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 连接

  Future<void> _connect() async {
    // 每一轮连接都从 init 重新计时：上一次失败的 failed 态必须清掉，
    // 否则 `go()` 会被状态机拒绝（见 ConnectProgress 的「失败后不再推进」）。
    _progress.reset();
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      _progress.go(ConnectStage.buildServer);
      final RoomConfig room = await _api.joinRoom(
        token: Settings.token,
        deviceId: widget.device.deviceId,
      );
      if (!mounted) return;
      _room = room;

      final String url = room.signalingUrl(
        deviceId: Settings.deviceId,
        apiBase: Settings.serverBase,
      );
      final SignalingClient signaling = SignalingClient(url: url);
      _signaling = signaling;
      _msgSub = signaling.messages.listen(_onMessage);
      await signaling.connect();
      if (!mounted) return;
      _progress.go(ConnectStage.syncInfo);
      setState(() => _connecting = false);
    } catch (e) {
      if (!mounted) return;
      // 失败既落在阶段机里（给等待页文案），也排一拍自动重连
      _progress.fail(e.toString());
      setState(() {
        _connecting = false;
        _error = e.toString();
      });
      _scheduleReconnect();
    }
  }

  /// 排一拍自动重连。已有待触发的一拍时不叠加（信令断开 + 首帧超时可能同时报）。
  ///
  /// 耗尽后不再自动重试：浮层改成「自动重连已停止，请手动重连」，
  /// 避免服务端挂死时客户端无限重连把设备列表刷爆。
  void _scheduleReconnect() {
    if (_reconnectTimer != null) return;
    final Duration? delay = _reconnectPolicy.next();
    if (delay == null) {
      if (mounted) setState(() => _reconnectIn = 0);
      return;
    }
    if (!mounted) return;
    setState(() => _reconnectIn = delay.inSeconds);
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      _reconnectIn = 0;
      if (mounted) unawaited(_reconnect());
    });
  }

  /// 会话通了：取消还没触发的那一拍，并把退避计数归零。
  ///
  /// 不归零的话下次断线会直接从上次的档位（可能 30 秒）起步，
  /// 用户会以为客户端卡死。
  void _clearReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectIn = 0;
    _reconnectPolicy.reset();
  }

  Future<void> _detach() async {
    await _frameSub?.cancel();
    _frameSub = null;
    await _msgSub?.cancel();
    _msgSub = null;
    _statsListenable?.removeListener(_onStats);
    _statsListenable = null;
    _stats = const TransportStats();
    _audioAvailable = false;
    _audioMuted = false;
    await _transport?.dispose();
    _transport = null;
    await _signaling?.close();
    _signaling = null;
    _hello = null;
    _agentError = null;
    _lastFrameAt = null;
    _stalled = false;
    _room = null;
    // 多屏/面板状态跟着会话一起清，避免重连到另一台设备时显示旧屏列表
    _screens = const <ScreenInfo>[];
    _screenId = 0;
    _latencyHistory.clear();
    _connectedAt = null;
  }

  Future<void> _reconnect() async {
    // 用户手动重连 = 主动介入，退避计数归零（否则下次故障又从 30 秒起步）
    _clearReconnect();
    await _detach();
    if (!mounted) return;
    await _connect();
  }

  // ------------------------------------------------------------ 信令消息

  void _onMessage(Map<String, dynamic> message) {
    switch (message['p']) {
      case 'agent.hello':
        _handleHello(AgentHello.fromJson(message));
      case 'peer.join':
        // 服务端会让房内既有节点重发 hello；这里不主动请求，等 Agent 发即可
        break;
      case 'screens':
        // 协议 v2 §3：`{p:"screens", current:0, list:[{id,w,h,x,y,name,primary}]}`
        final List<ScreenInfo> list = ScreenInfo.listFrom(message['list']);
        final int current = _asInt(message['current']);
        if (!mounted) return;
        setState(() {
          _screens = list;
          _screenId = current;
        });
      case 'screen.selected':
        final int id = _asInt(message['id']);
        if (!mounted) return;
        setState(() => _screenId = id);
        _toast('已切换到${_screenLabel(id)}');
      case 'stream.config.ack':
        final Object? w = message['width'];
        final Object? f = message['fps'];
        final Object? br = message['bitrate'];
        _toast('画质已切换：${w}px · ${f}fps${br == null ? '' : ' · ${br}kbps'}');
      case 'power.state':
        _powerStateSeen = true;
        _onPowerState(message);
      case 'shutdown.state':
        // 兼容 <=0.2.0 的 Agent（只发 shutdown.state）
        if (!_powerStateSeen) {
          _onPowerState(<String, dynamic>{
            ...message,
            'action': 'shutdown',
          });
        }
      case 'privacy.state':
        final bool ok = message['ok'] == true;
        final String mode = _txt(message['mode']);
        if (!mounted) return;
        _setSecurity(_security.copyWith(
            privacy: PrivacyMode.fromKey(mode),
            engine: message['engine'] == null
                ? _security.engine
                : _txt(message['engine']),
            error: ok ? null : _txt(message['err'], '防窥设置失败'),
            clearError: ok,
          ));
        if (ok) {
          final PrivacyMode m = PrivacyMode.fromKey(mode);
          _toast(m == PrivacyMode.off ? '已解除防窥' : '已开启${m.label}');
        }
      case 'security.state':
        final bool muteOk = message['mute_ok'] != false;
        if (!mounted) return;
        _setSecurity(_security.copyWith(
            autoLock: message['auto_lock'] == null
                ? _security.autoLock
                : message['auto_lock'] == true,
            muted: message['mute'] == null ? _security.muted : message['mute'] == true,
            error: muteOk ? null : _txt(message['err'], '静音失败'),
            clearError: true,
          ));
      case 'clip':
        _onClip(message);
      case 'clip.sync':
        // Agent 主动回执开关态（当前版本只在收到指令后改内部状态、不回发，
        // 这里兼容将来加回执的版本：以被控端为准，避免 UI 显示与实际不一致）
        final Object? en = message['enable'];
        if (en is bool && mounted) {
          setState(() => _clip.enabled = en);
        }
      case 'agent.error':
        _onAgentError(message['err']);
      default:
        break;
    }
  }

  /// `{p:"clip", dir:"down", text}`：被控端复制了内容 → 写进本机剪贴板。
  ///
  /// 静默写入是刻意的：用户在被控端按 Ctrl+C，本机剪贴板跟着变是预期行为，
  /// 每次都弹 toast 会把画面糊满。只有被护栏挡下（超长）才提示一次。
  void _onClip(Map<String, dynamic> message) {
    if (message['dir'] != 'down') return;
    unawaited(_applyRemoteClip(message['text']?.toString() ?? ''));
  }

  Future<void> _applyRemoteClip(String text) async {
    final ClipboardApplyResult result = await _clip.applyRemote(text);
    if (!mounted) return;
    if (result == ClipboardApplyResult.skippedTooLong) {
      _toast('被控端剪贴板内容过长，已跳过同步');
    }
  }

  /// 解析持久化的 JSON 对象。空串或坏数据返回 null，让调用方走默认值——
  /// 快捷键表/小窗偏好坏了只该「回到出厂」，不该让进远控页失败。
  static Map<String, dynamic>? _jsonObject(String raw) {
    if (raw.isEmpty) return null;
    try {
      final Object? value = jsonDecode(raw);
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }

  static int _asInt(Object? v, [int fallback = 0]) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  static String _txt(Object? v, [String fallback = '']) {
    final String s = v?.toString() ?? '';
    return s.isEmpty ? fallback : s;
  }

  /// `power.state`：pending 显示倒计时条，其余状态 toast 收尾。
  void _onPowerState(Map<String, dynamic> message) {
    final PowerAction? action = PowerAction.fromKey(_txt(message['action']));
    final String state = _txt(message['state']);
    if (action == null || !mounted) return;
    switch (state) {
      case 'pending':
        setState(() => _countdown = PowerCountdown(
              action: action,
              remain: _asInt(message['remain'], 30),
            ));
      case 'executing':
        setState(() => _countdown = null);
        _toast('${action.label}指令已下发');
      case 'done':
        setState(() => _countdown = null);
        _toast('${action.label}已完成');
      case 'cancelled':
        setState(() => _countdown = null);
        _toast('已撤销${action.label}');
      case 'failed':
        setState(() => _countdown = null);
        _toast('${action.label}失败：${_txt(message['err'], '被控端未说明原因')}');
    }
  }

  void _openSecurityPanel() {
    showSecurityPanel(
      context,
      state: _securityVN,
      onPrivacy: (PrivacyMode m) {
        // 先本地点亮，避免等被控端回执期间点第二下；失败时会被回执覆盖回来
        _setSecurity(_security.copyWith(privacy: m, clearError: true));
        _send(<String, dynamic>{'p': 'privacy', 'mode': m.key});
      },
      onAutoLock: (bool v) {
        _setSecurity(_security.copyWith(autoLock: v, clearError: true));
        _send(<String, dynamic>{'p': 'security.config', 'auto_lock': v});
      },
      onMute: (bool v) {
        _setSecurity(_security.copyWith(muted: v, clearError: true));
        _send(<String, dynamic>{'p': 'security.config', 'mute': v});
      },
    );
  }

  void _openPowerPanel() {
    final AgentHello? hello = _hello;
    showPowerPanel(
      context,
      supports: (String action) => hello?.supportsPower(action) ?? action == 'shutdown',
      onAction: (PowerAction a) => _send(<String, dynamic>{
        'p': 'power',
        'action': a.key,
        if (a.needsCountdown) 'delay': 30,
      }),
    );
  }

  void _cancelPower() {
    final PowerCountdown? c = _countdown;
    if (c == null) return;
    _send(<String, dynamic>{'p': 'power', 'action': c.action.key, 'cancel': true});
  }

  String _screenLabel(int id) {
    for (final ScreenInfo s in _screens) {
      if (s.id == id) return s.label;
    }
    return '显示屏 ${id + 1}';
  }

  /// 切屏（协议 v2 §3）。单屏时按官方文案给提示，不发无效请求。
  void _selectScreen(int id) {
    if (_screens.length <= 1) {
      _toast('当前远程窗口仅有 1 个屏幕，无需切换');
      return;
    }
    if (id == _screenId) return;
    _signaling?.sendJson(<String, dynamic>{'p': 'screen.select', 'id': id});
  }

  /// `agent.error` 的已知错误码 → 人话。
  ///
  /// `screen_permission`：Agent 侧 `screens == 0`（显示器全关/合盖，或缺屏幕录制授权），
  /// 这时它仍会发 hello，但画面永远是空的——必须常驻提示，不能只弹一个 toast 然后转圈。
  void _onAgentError(Object? code) {
    final String text = describeAgentError(code);
    _toast(text);
    if (!mounted) return;
    setState(() => _agentError = text);
  }

  Future<void> _handleHello(AgentHello hello) async {
    if (!mounted || _applyingHello) return;
    _applyingHello = true;
    try {
      await _applyHello(hello);
    } finally {
      _applyingHello = false;
    }
  }

  Future<void> _applyHello(AgentHello hello) async {
    // 收到 hello = 已连上被控端，进入「同步设备信息 / 下发串流设置」两阶段
    _progress.go(ConnectStage.setting);
    final AgentHello? previous = _hello;
    final bool needNewTransport = previous == null ||
        previous.isWebRtc != hello.isWebRtc ||
        previous.audio != hello.audio ||
        previous.width != hello.width ||
        previous.height != hello.height;

    setState(() {
      _hello = hello;
      // 新 hello = 被控端重来一次，旧的错误提示作废（随后若仍有问题会再收到 agent.error）
      _agentError = null;
      _connectedAt ??= DateTime.now();
      // hello 里带了安全能力面：防窥引擎、autoLock、电源动作白名单
      _securityVN.value = SecurityState.fromHello(hello);
      if (hello.width > 0 && hello.height > 0) {
        _screen = Size(hello.width.toDouble(), hello.height.toDouble());
      }
    });
    // Agent 的剪贴板同步**默认关闭**（`agent/clipboard_sync.py` 里 `self.enabled = False`），
    // 必须由控制端显式打开，否则永远收不到 `dir:"down"`。
    // 放在早退之前：复用 transport 的重连路径也要重新对齐开关态。
    _send(InputEvent.clipSync(_clip.enabled));

    if (!needNewTransport && _transport != null) return;
    final RoomConfig? room = _room;
    final SignalingClient? signaling = _signaling;
    if (room == null || signaling == null) return;

    await _frameSub?.cancel();
    _frameSub = null;
    _statsListenable?.removeListener(_onStats);
    _statsListenable = null;
    // 新通路 = 新会话，音频状态一并归零（否则 UI 显示静音但新媒体其实在放）
    _audioAvailable = false;
    _audioMuted = false;
    final MediaTransport? old = _transport;
    _transport = null;
    await old?.dispose();

    final MediaTransport transport = createTransport(hello);
    try {
      await transport.start(hello: hello, room: room, signaling: signaling);
      if (!mounted) {
        await transport.dispose();
        return;
      }
      if (transport is WebRtcTransport) {
        // 运行中 failed/disconnected → 回落 JPEG（协议 §5）
        transport.onFallback = _onWebRtcFallback;
      }
      setState(() => _transport = transport);
      _bindStats(transport);
      _frameSub = transport.frames.listen(_onFrame);
      // 通路已建好（WebRTC 协商完成 / JPEG 直连）→ 链路就绪
      _progress.go(ConnectStage.optimized);
      if (transport is WebRtcTransport) {
        // 协商期（answer 之前）就失败的，上面那个回调来不及接住，这里补一刀
        final String? reason = transport.fallbackReason;
        if (reason != null) await _fallbackFromWebRtc(reason);
      }
    } catch (e) {
      await transport.dispose();
      if (!hello.isWebRtc) {
        if (mounted) setState(() => _error = '画面通路初始化失败：$e');
        return;
      }
      // WebRTC 起不来（平台不支持 / 建 PC 失败）→ JPEG 兜底（协议 §5）
      final bool ok = await _installJpegFallback(hello, room, signaling);
      if (!mounted) return;
      if (ok) {
        _toast('H.264 直连不可用，已回落 JPEG：$e');
      }
    }
    // 推流已开始，接下来只等第一帧（`_onFrame` 收到首帧后落到 success）
    _progress.go(ConnectStage.transmitting);
    _applyQuality();
  }

  /// 装 JPEG 兜底通路；成功返回 true。
  Future<bool> _installJpegFallback(
    AgentHello hello,
    RoomConfig room,
    SignalingClient signaling,
  ) async {
    final JpegTransport fallback = JpegTransport();
    try {
      await fallback.start(hello: hello, room: room, signaling: signaling);
    } catch (e) {
      await fallback.dispose();
      if (mounted) setState(() => _error = '画面通路初始化失败：$e');
      return false;
    }
    if (!mounted) {
      await fallback.dispose();
      return false;
    }
    setState(() => _transport = fallback);
    _bindStats(fallback);
    _frameSub = fallback.frames.listen(_onFrame);
    // JPEG 没有 ICE/协商，`optimized` 的 hint 里也写了「兜底会跳过这一步」，
    // 这里仍然推进一档，保证等待页文案与进度条不跳号
    _progress.go(ConnectStage.optimized);
    return true;
  }

  /// WebRTC 中途断链（`connectionState` failed/disconnected）→ 切回 JPEG。
  ///
  /// 用同步壳包一层：传输层是在原生回调/计时器里调它，返回的 Future 没人 await，
  /// 一旦这里抛异常就会变成 Zone 顶层未捕获错误。
  void _onWebRtcFallback(String reason) {
    unawaited(_fallbackFromWebRtc(reason).catchError((Object e) {
      debugPrint('[webrtc] 回落 JPEG 失败：$e');
    }));
  }

  Future<void> _fallbackFromWebRtc(String reason) async {
    final RoomConfig? room = _room;
    final SignalingClient? signaling = _signaling;
    final AgentHello? hello = _hello;
    if (!mounted || _transport is! WebRtcTransport) return;
    if (room == null || signaling == null || hello == null) return;

    await _frameSub?.cancel();
    _frameSub = null;
    _statsListenable?.removeListener(_onStats);
    _statsListenable = null;
    final MediaTransport? old = _transport;
    _transport = null;
    _stats = const TransportStats();
    if (mounted) setState(() {});
    await old?.dispose();

    final bool ok = await _installJpegFallback(hello, room, signaling);
    if (ok && mounted) _toast('H.264 直连中断（$reason），已回落 JPEG');
  }

  void _bindStats(MediaTransport transport) {
    _statsListenable?.removeListener(_onStats);
    _statsListenable = transport.stats;
    _statsListenable?.addListener(_onStats);
  }

  /// WebRTC 没有帧流，喂看门狗和 fps 的只有 getStats()。
  void _onStats() {
    final TransportStats? stats = _statsListenable?.value;
    if (stats == null) return;
    if ((stats.fps ?? 0) > 0) _lastFrameAt = DateTime.now();
    // 连接信息面板的「当前/平均/最高」延时：按拍采样，保留最近 60 拍
    final int? rtt = stats.rttMs;
    if (rtt != null) {
      _latencyHistory.add(rtt);
      if (_latencyHistory.length > 60) _latencyHistory.removeAt(0);
    }
    if (!mounted) return;
    setState(() => _stats = stats);
  }

  /// 打开展示连接信息面板（官方「网络状态」入口）。
  void _showInfo() {
    showRemoteInfoDialog(
      context,
      buildRemoteInfoData(
        deviceName: widget.device.name,
        device: widget.device,
        hello: _hello,
        stats: _stats,
        transportKind: _transport?.kind,
        connectedAt: _connectedAt,
        screenIndex: _screenId,
        screenCount: _screens.isEmpty ? (_hello?.screens ?? 1) : _screens.length,
        audioAvailable: _audioAvailable,
        audioMuted: _audioMuted,
        qualityLabel: _quality.label,
        clientVersion: kAppVersion,
        latencyHistory: _latencyHistory,
      ),
    );
  }

  void _applyQuality() {
    final SignalingClient? signaling = _signaling;
    if (signaling == null || !signaling.isOpen || _hello == null) return;
    signaling.sendJson(InputEvent.streamConfig(
      width: _quality.width,
      quality: _quality.preset.quality,
      fps: _quality.fps,
      bitrate: _quality.bitrate,
    ));
  }

  void _onFrame(FramePacket packet) {
    _framesInWindow++;
    _lastFrameAt = DateTime.now();
    _latency = packet.latency;
    // 首帧 = 会话真的通了：阶段收尾 + 退避计数归零（否则下次断线从 30 秒起步）
    final bool firstFrame = !_progress.stage.isReady;
    if (firstFrame) {
      _progress.go(ConnectStage.success);
      _clearReconnect();
    }
    if (!mounted) return;
    if (_stalled || firstFrame) setState(() => _stalled = false);
  }

  void _onTick() {
    if (!mounted) return;
    // 音频轨到达是异步的（onTrack），跟 fps 一样按秒级刷新即可
    final bool audioReady = _transport?.hasAudio ?? false;
    if (audioReady != _audioAvailable && mounted) {
      setState(() => _audioAvailable = audioReady);
    }
    final DateTime? last = _lastFrameAt;
    // 首帧未到时由占位视图提示「等待画面」，这里只处理「曾经有帧、现在断了」
    final bool stalled = _transport != null &&
        last != null &&
        DateTime.now().difference(last) > AppConfig.frameWatchdog;
    setState(() {
      _fps = _framesInWindow;
      _framesInWindow = 0;
      _stalled = stalled;
    });

    // 画面断了就排一拍自动重连；已经排过在等的那一拍不叠加。
    // 只处理「曾经出过画面、现在断了」——首连失败由 `_connect` 的 catch 兜。
    if (stalled && _reconnectTimer == null) {
      _scheduleReconnect();
    } else if (_reconnectIn > 0) {
      setState(() => _reconnectIn--);
    }

    // 本机剪贴板有变化就上行：没有这条，控制端复制的文字远端 Cmd+V 粘不到
    _pollClipboardUpload();
  }

  /// 每秒探一次本机剪贴板，有新内容就上行（`{p:"clip", dir:"up"}`）。
  ///
  /// 轮询而不是监听：Flutter 没有跨平台的剪贴板变更事件，官方客户端同样按拍轮询。
  /// 去重交给 [ClipboardSync]——同值不会重复发，也不会把下行来的内容反推回去。
  void _pollClipboardUpload() {
    if (!_clip.enabled || _transport == null) return;
    unawaited(() async {
      final String? text = await _clip.takeLocalForUpload();
      if (text == null || !mounted) return;
      _send(InputEvent.clipUp(text));
      _clip.markUploaded(text);
    }());
  }

  /// 剪贴板同步开关：本地落盘 + 通知被控端（Agent 侧默认关闭，必须显式打开）。
  void _toggleClipboardSync() {
    final bool next = !_clip.enabled;
    setState(() => _clip.enabled = next);
    unawaited(Settings.setClipboardSync(next));
    _send(InputEvent.clipSync(next));
    _toast(next ? '剪贴板双向同步已开启' : '剪贴板同步已关闭（两个方向都停）');
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  // ------------------------------------------------------------ 桌面外壳

  /// 全屏切换。桌面走 window_manager，移动端走系统沉浸式。
  /// 切换观看模式三态。离开批注态前必须收笔：否则那笔会一直挂在
  /// `_active` 上，下次回来表现为「多出一条莫名其妙的线」。
  void _setViewState(ViewState next) {
    if (_viewMode.state == ViewState.annotation) _annotations.end();
    // 切出操控态：先把按住的修饰键放掉，再告知被控端「只看不控」。
    // 两头都做是有意的——本地一旦漏掉某个键（失焦、组合键被系统吃掉），
    // 远端还有一次 release_all 兜底，不会留下「Shift 一直按着」的状态。
    final bool leavingControl =
        _viewMode.state == ViewState.control && next != ViewState.control;
    final bool enteringControl =
        _viewMode.state != ViewState.control && next == ViewState.control;
    if (leavingControl) {
      _releaseHeldMods();
      _signaling?.sendJson(InputEvent.viewOnly(true));
    } else if (enteringControl) {
      _signaling?.sendJson(InputEvent.viewOnly(false));
    }
    setState(() {
      _viewMode = _viewMode.copyWith(
        state: next,
        // 回到操控态时把缩放也归位，否则用户会以为「画面怎么是歪的」
        transform: next == ViewState.control ? const ViewTransform() : _viewMode.transform,
        toolbarVisible: true,
      );
    });
  }

  /// 批注开关。从操控态直接开批注时先进观看态，因为批注本身不发送输入。
  void _toggleAnnotation() {
    _setViewState(
      _viewMode.state == ViewState.annotation ? ViewState.view : ViewState.annotation,
    );
  }

  /// 缩放：以视口中心为锚点（键盘操作没有鼠标位置，中心最符合预期）。
  void _zoomBy(double factor) {
    setState(() {
      _viewMode = _viewMode.copyWith(
        transform: _viewMode.transform.zoomAt(
          focal: Offset(_stageSize.width / 2, _stageSize.height / 2),
          factor: factor,
          viewport: _stageSize,
        ),
      );
    });
  }

  void _resetZoom() {
    setState(() => _viewMode = _viewMode.copyWith(transform: const ViewTransform()));
  }

  // ---------------------------------------------------------- 小窗模式

  /// 进入/退出小窗（官方 B5）：置顶 + 透明度 + 单设备。
  ///
  /// 只做窗口几何与层级，不动视频通路——通路重建会黑屏一两秒，
  /// 而小窗的使用场景恰恰是「瞟一眼」，不能闪。
  Future<void> _toggleMiniWindow() async {
    if (!_isDesktop) {
      _toast('小窗模式只在桌面端可用');
      return;
    }
    final bool next = !_mini.enabled;
    if (next) {
      // 记住原几何，退出时还原（否则用户回不到原来的窗口位置）
      try {
        _windowBeforeMini = await windowManager.getBounds();
      } catch (_) {
        _windowBeforeMini = null;
      }
      final Size screen = await _logicalScreenSize();
      final Size desktop = Size(
        (_hello?.width ?? 0).toDouble(),
        (_hello?.height ?? 0).toDouble(),
      );
      final Size size = MiniWindowLayout.windowSize(
        screen: screen,
        desktopResolution: desktop,
        size: _mini.size,
      );
      final Offset pos = MiniWindowLayout.initialPosition(screen: screen, window: size);
      try {
        // 先退全屏再改尺寸：某些平台在全屏态下 setSize 会被忽略
        if (_fullscreen) await _setFullscreen(false);
        await windowManager.setAlwaysOnTop(_mini.alwaysOnTop);
        await windowManager.setSize(size);
        await windowManager.setPosition(pos);
        // 窗口级透明度：控制条会一起变淡，所以下限放在 0.5 以上
        await windowManager.setOpacity(_mini.opacity.clamp(0.5, 1.0));
      } catch (_) {
        _toast('当前平台不支持小窗（窗口插件不可用）');
        return;
      }
    } else {
      try {
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setOpacity(1.0);
        final Rect? previous = _windowBeforeMini;
        if (previous != null) {
          await windowManager.setBounds(previous);
        }
      } catch (_) {
        // 插件失败时仍然退出小窗状态，避免卡在一个「标示为小窗」的普通窗口里
      }
      _windowBeforeMini = null;
    }
    if (!mounted) return;
    setState(() => _mini = _mini.copyWith(enabled: next));
    unawaited(Settings.setMiniWindowJson(jsonEncode(_mini.toJson())));
  }

  /// 打开快捷键设置（官方 B6.1，22 项）。改完立刻生效并落盘。
  void _openShortcuts() {
    unawaited(showShortcutsPanel(
      context,
      map: _shortcuts,
      onChanged: (ShortcutMap next) {
        if (!mounted) return;
        setState(() => _shortcuts = next);
        unawaited(Settings.setShortcutsJson(jsonEncode(next.toJson())));
      },
    ));
  }

  /// 打开小窗设置面板（置顶/透明度/尺寸/退出）。
  void _openMiniWindowPanel() {
    unawaited(showMiniWindowPanel(
      context,
      state: _mini,
      supported: _isDesktop,
      onChange: (MiniWindowState next) {
        if (!mounted) return;
        final bool turningOn = next.enabled && !_mini.enabled;
        final bool turningOff = !next.enabled && _mini.enabled;
        setState(() => _mini = next);
        unawaited(Settings.setMiniWindowJson(jsonEncode(next.toJson())));
        // 开关类改动要走完整的进出流程（保存/还原窗口几何），
        // 只改透明度/尺寸则直接应用，不重建窗口。
        if (turningOn || turningOff) {
          unawaited(_toggleMiniWindow());
        } else if (_mini.enabled) {
          unawaited(_applyMiniPrefs());
        }
      },
      onExitMini: () {
        if (_mini.enabled) unawaited(_toggleMiniWindow());
      },
    ));
  }

  /// 把小窗偏好（置顶/透明度/尺寸）应用到当前窗口，不动进出状态。
  Future<void> _applyMiniPrefs() async {
    if (!_isDesktop) return;
    try {
      await windowManager.setAlwaysOnTop(_mini.alwaysOnTop);
      await windowManager.setOpacity(_mini.opacity.clamp(0.5, 1.0));
      final Size screen = await _logicalScreenSize();
      final Size size = MiniWindowLayout.windowSize(
        screen: screen,
        desktopResolution: Size(
          (_hello?.width ?? 0).toDouble(),
          (_hello?.height ?? 0).toDouble(),
        ),
        size: _mini.size,
      );
      await windowManager.setSize(size);
    } catch (_) {
      // 忽略：偏好应用失败不该中断远控
    }
  }

  /// 屏幕逻辑尺寸（不含任务栏的近似值）。
  ///
  /// 不能用当前窗口尺寸去推——小窗正是要「从窗口缩出去」，拿窗口当屏幕
  /// 会算出过小的目标尺寸。取 platformDispatcher 的 display 更直接。
  Future<Size> _logicalScreenSize() async {
    try {
      final FlutterView view = WidgetsBinding.instance.platformDispatcher.views.first;
      final Size physical = view.display.size;
      final double dpr = view.devicePixelRatio;
      if (dpr <= 0 || physical.isEmpty) return const Size(1280, 800);
      return physical / dpr;
    } catch (_) {
      return const Size(1280, 800);
    }
  }

  Future<void> _setFullscreen(bool on) async {
    setState(() {
      _fullscreen = on;
      _chromeVisible = true;
    });
    if (_isDesktop) {
      try {
        await windowManager.setFullScreen(on);
      } catch (_) {
        // 插件不可用时忽略：不影响远控主流程
      }
    } else {
      await SystemChrome.setEnabledSystemUIMode(
        on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    }
    if (_autoHideChrome) _scheduleChromeHide();
  }

  /// 工具栏自动隐藏（官方 B9-1：鼠标离开边缘后淡出，移到顶部/底部唤出）。
  /// 只对桌面端启用——移动端没有悬浮指针，隐藏后用户找不到返回入口。
  bool get _autoHideChrome => _isDesktop;

  void _scheduleChromeHide() {
    _chromeTimer?.cancel();
    if (!_autoHideChrome) return;
    _chromeTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _chromeVisible = false);
    });
  }

  void _pokeChrome() {
    if (!_autoHideChrome) return;
    if (!_chromeVisible) setState(() => _chromeVisible = true);
    _scheduleChromeHide();
  }

  /// 本地静音开关：只调本机音量，不发任何信令（协议 v2 §1）。
  void _toggleAudio() {
    final bool next = !_audioMuted;
    setState(() => _audioMuted = next);
    _transport?.setAudioMuted(next);
  }

  Future<void> _sendClipboardText() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String? text = data?.text;
    if (text == null || text.isEmpty) {
      _toast('剪贴板里没有文字');
      return;
    }
    _send(InputEvent.text(text));
    _toast('已发送 ${text.length} 个字符');
  }

  // ------------------------------------------------------------ 输入

  void _send(Map<String, dynamic> event) {
    final SignalingClient? signaling = _signaling;
    if (signaling == null || !signaling.isOpen) return;
    signaling.sendJson(event);
  }

  /// 屏幕坐标 → 协议归一化坐标（0..1），几何与 `BoxFit.contain` 完全一致。
  Offset _normalize(Offset local, Size box) {
    final Size screen = _screen;
    if (box.width <= 0 || box.height <= 0 || screen.width <= 0 || screen.height <= 0) {
      return Offset.zero;
    }
    final double scale = math.min(box.width / screen.width, box.height / screen.height);
    final double dw = screen.width * scale;
    final double dh = screen.height * scale;
    final double ox = (box.width - dw) / 2;
    final double oy = (box.height - dh) / 2;
    final double x = ((local.dx - ox) / dw).clamp(0.0, 1.0);
    final double y = ((local.dy - oy) / dh).clamp(0.0, 1.0);
    return Offset(x, y);
  }

  void _sendMove(Offset local, Size box, {bool force = false}) {
    final DateTime now = DateTime.now();
    if (!force && now.difference(_lastSentAt) < AppConfig.inputThrottle) return;
    final Offset p = _normalize(local, box);
    final Offset? last = _lastSent;
    if (!force && last != null && (last.dx - p.dx).abs() < 0.0004 && (last.dy - p.dy).abs() < 0.0004) {
      return;
    }
    _lastSent = p;
    _lastSentAt = now;
    _send(InputEvent.move(p.dx, p.dy));
  }

  void _onPointerDown(PointerDownEvent event, Size box) {
    _focusNode.requestFocus();
    _pokeChrome();

    // 批注态：起笔。点用「视口归一化」坐标，和 AnnotationBoard 的约定一致，
    // 窗口缩放/全屏切换都不用重算。批注期间画面锁定 identity（见 _setViewState）。
    if (_viewMode.state == ViewState.annotation) {
      _annotations.begin(
        _normalizeToBox(event.localPosition, box),
        colorArgb: _penColor.toARGB32(),
      );
      setState(() {});
      return;
    }
    // 观看态：拖拽平移画面，不产生任何远端点击
    if (_viewMode.state == ViewState.view) {
      _panLast = event.localPosition;
      return;
    }

    // 桌面鼠标按键直通（官方 D1：主/次/中/后退/前进 五键）。pyautogui 的
    // button 只认 left/right/middle，侧键（back/forward）需要被控端 SendInput，
    // 见 docs/远控复刻基线.md —— 这里先把三键跑通，侧键留 P2。
    final int buttons = event.buttons;
    if (buttons == kSecondaryMouseButton || buttons == kMiddleMouseButton) {
      final Offset p = _normalize(event.localPosition, box);
      _send(InputEvent.click(p.dx, p.dy, btn: buttons == kSecondaryMouseButton ? 'right' : 'middle'));
      return;
    }
    _downAt = event.localPosition;
    _downTime = DateTime.now();
    _dragged = false;
    _longPressFired = false;
    _sendMove(event.localPosition, box, force: true);
    // 移动端没有右键：长按 550ms = 右键单击（与 control.html 一致）
    _longPress?.cancel();
    _longPress = Timer(const Duration(milliseconds: 550), () {
      final Offset? down = _downAt;
      if (!mounted || _dragged || down == null) return;
      final Offset p = _normalize(down, box);
      _send(InputEvent.click(p.dx, p.dy, btn: 'right'));
      _longPressFired = true;
    });
  }

  void _onPointerMove(PointerMoveEvent event, Size box) {
    if (_viewMode.state == ViewState.annotation) {
      if (_annotations.extend(_normalizeToBox(event.localPosition, box))) {
        setState(() {});
      }
      return;
    }
    if (_viewMode.state == ViewState.view) {
      final Offset? last = _panLast;
      _panLast = event.localPosition;
      if (last == null) return;
      final Offset delta = event.localPosition - last;
      if (delta == Offset.zero) return;
      setState(() {
        _viewMode = _viewMode.copyWith(
          transform: _viewMode.transform.pan(delta, box),
        );
      });
      return;
    }

    // 只有靠近画面上下边缘才唤出工具栏，否则鼠标在中间动一下就常驻了
    if (event.localPosition.dy < 48 || event.localPosition.dy > box.height - 48) {
      _pokeChrome();
    }
    final Offset? down = _downAt;
    if (down != null && (event.localPosition - down).distance > 6) {
      _dragged = true;
      _longPress?.cancel();
    }
    _sendMove(event.localPosition, box);
  }

  void _onPointerUp(PointerUpEvent event, Size box) {
    if (_viewMode.state == ViewState.annotation) {
      _annotations.end();
      setState(() {});
      return;
    }
    if (_viewMode.state == ViewState.view) {
      _panLast = null;
      return;
    }

    final Offset? down = _downAt;
    final DateTime? downAt = _downTime;
    _longPress?.cancel();
    _downAt = null;
    _downTime = null;
    if (down == null || downAt == null) return;
    final bool isTap = !_dragged &&
        !_longPressFired &&
        DateTime.now().difference(downAt) < const Duration(milliseconds: 550);
    _dragged = false;
    _longPressFired = false;
    if (!isTap) return;
    final Offset p = _normalize(event.localPosition, box);
    _send(InputEvent.click(p.dx, p.dy));
  }

  /// 视口归一化（0..1），不做「保持画面比例」的信箱校正。
  ///
  /// 和 [_normalize] 的区别：那个要把坐标映射到远端桌面（BoxFit.contain 的
  /// 黑边要扣掉），批注是画在本机叠加层上的，坐标轴就是视口本身。
  Offset _normalizeToBox(Offset local, Size box) {
    if (box.isEmpty) return Offset.zero;
    return Offset(
      (local.dx / box.width).clamp(0.0, 1.0),
      (local.dy / box.height).clamp(0.0, 1.0),
    );
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      // 与 control.html 一致：滚轮向上（deltaY<0）→ dy=3。
      // 带上当前修饰键（协议 v2 §4），否则远端收不到 Ctrl+滚轮缩放。
      final HardwareKeyboard kb = HardwareKeyboard.instance;
      final List<String> mods = <String>[
        if (kb.isControlPressed) 'ctrl',
        if (kb.isShiftPressed) 'shift',
        if (kb.isAltPressed) 'alt',
        if (kb.isMetaPressed) 'win',
      ];
      _send(InputEvent.scroll(event.scrollDelta.dy < 0 ? 3 : -3, mods: mods));
    }
  }

  /// 快捷键先拦截本机操作，再透传给被控端。
  /// 按键 → 规范化组合。
  ///
  /// 修饰键必须**在按下这一瞬间**取：等 KeyUp 时用户手已经松了，
  /// 拿到的永远是空集合，快捷键全部失灵。
  KeyChord? _chordOf(KeyEvent event) {
    final String label = event.logicalKey.keyLabel;
    if (label.isEmpty) return null;
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final Set<String> mods = <String>{};
    if (keyboard.isMetaPressed) mods.add('meta');
    if (keyboard.isControlPressed) mods.add('ctrl');
    if (keyboard.isAltPressed) mods.add('alt');
    if (keyboard.isShiftPressed) mods.add('shift');
    return KeyChord(key: label, modifiers: mods);
  }

  bool _handleShortcut(KeyEvent event) {
    // 只认 KeyDownEvent：长按产生的 KeyRepeatEvent 会让「切全屏」疯狂来回切。
    if (event is! KeyDownEvent) return false;
    final KeyChord? chord = _chordOf(event);
    if (chord == null) return false;

    // 两个兜底：官方 22 项里没有它们，但都是肌肉记忆，硬编码保留。
    // 顺序放在配置表之前，用户改绑别的键也不会把这两个弄丢。
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        chord.modifiers.isEmpty &&
        _fullscreen) {
      _setFullscreen(false);
      return true;
    }
    if (chord.key == 'F5' &&
        !chord.modifiers.contains('meta') &&
        chord.modifiers.contains('ctrl')) {
      _reconnect();
      return true;
    }

    ShortcutAction? action = _shortcuts.actionFor(chord);
    // 默认表统一用 meta 当主修饰（⌘），但 Windows/Linux 用户习惯 Ctrl。
    // 原样查不到时把 ctrl 换成 meta 再查一次，否则平台默认键位全部不生效。
    if (action == null && !Platform.isMacOS && chord.modifiers.contains('ctrl')) {
      final Set<String> swapped = <String>{...chord.modifiers}
        ..remove('ctrl')
        ..add('meta');
      action = _shortcuts.actionFor(KeyChord(key: chord.key, modifiers: swapped));
    }
    if (action == null) return false;

    _dispatchShortcut(action);
    return true;
  }

  /// 执行快捷键动作。命中过的组合不再发给被控端（「优先在控制端响应」，
  /// 官方三档策略里的默认档 `controllerFirst`）。
  void _dispatchShortcut(ShortcutAction action) {
    switch (action) {
      case ShortcutAction.fullScreen:
        _setFullscreen(!_fullscreen);
        break;
      case ShortcutAction.quitRemote:
        unawaited(_confirmExit());
        break;
      case ShortcutAction.ctrlAltDelete:
        _send(<String, dynamic>{
          'p': 'input',
          't': 'key',
          'combo': <String>['ctrl', 'alt', 'delete'],
        });
        break;
      case ShortcutAction.muteController:
        _toggleAudio();
        break;
      case ShortcutAction.networkStatus:
        setState(() => _showHud = !_showHud);
        break;
      case ShortcutAction.previousScreen:
        _stepScreen(-1);
        break;
      case ShortcutAction.nextScreen:
        _stepScreen(1);
        break;
      case ShortcutAction.paste:
        _sendClipboardText();
        break;
      case ShortcutAction.viewMode:
        _setViewState(ViewState.view);
        break;
      case ShortcutAction.viewModeToggle:
        _setViewState(
          _viewMode.state == ViewState.control ? ViewState.view : ViewState.control,
        );
        break;
      case ShortcutAction.viewModeToggleAnnotation:
        _toggleAnnotation();
        break;
      case ShortcutAction.viewModeToggleToolbar:
        setState(() => _viewMode =
            _viewMode.copyWith(toolbarVisible: !_viewMode.toolbarVisible));
        break;
      case ShortcutAction.smallWindowMode:
        unawaited(_toggleMiniWindow());
        break;
      // 功能本体还没做的：明确告知，而不是静默吞掉按键
      // （用户会以为键盘失灵，或者以为快捷键没配上）。
      case ShortcutAction.bossKey:
      case ShortcutAction.fileTransfer:
      case ShortcutAction.floatingBall:
      case ShortcutAction.lockMouse:
      case ShortcutAction.privacyMode:
      case ShortcutAction.privacyScreenSaver:
      case ShortcutAction.remoteMouseMode:
      case ShortcutAction.switchRemoteWindow:
      case ShortcutAction.screenshot:
        _toast('「${action.label}」还没做，先不占用这个组合也可以删掉');
        break;
    }
  }

  /// 按方向切屏。单屏时保持不动（不弹错误，用户按错而已）。
  void _stepScreen(int delta) {
    if (_screens.length < 2) return;
    final int index = _screens.indexWhere((ScreenInfo s) => s.id == _screenId);
    final int next = (index + delta) % _screens.length;
    _selectScreen(_screens[(next + _screens.length) % _screens.length].id);
  }

  void _handleKey(KeyEvent event) {
    if (_handleShortcut(event)) return;

    if (event is KeyUpEvent) {
      final String? mod = RemoteKeyMapper.modifierName(event.logicalKey);
      if (mod != null && _heldMods.remove(mod)) _send(InputEvent.keyUp(mod));
      return;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;
    if (!_keyboardLock) return;

    final String? mod = RemoteKeyMapper.modifierName(event.logicalKey);
    if (mod != null) {
      if (_heldMods.add(mod)) _send(InputEvent.keyDown(mod));
      return;
    }

    final String? character = event.character;
    if (character != null &&
        character.isNotEmpty &&
        character.codeUnitAt(0) >= 0x20 &&
        character != '\u007F' &&
        _heldMods.isEmpty) {
      _send(InputEvent.text(character));
      return;
    }
    final String? name = RemoteKeyMapper.keyName(event.logicalKey);
    if (name != null) _send(InputEvent.press(name));
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final bool wide = Breakpoints.isMedium(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        top: !_fullscreen,
        bottom: !_fullscreen,
        child: Column(
          children: <Widget>[
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              child: _chromeVisible ? _topBar(wide) : const SizedBox(width: double.infinity),
            ),
            Expanded(child: _stage()),
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              child: !_chromeVisible
                  ? const SizedBox(width: double.infinity)
                  // 观看/批注态用观看工具条替换底栏：底栏那排（键盘、粘贴、
                  // Ctrl+Alt+Del）在观看态全都不生效，留着只会让人误点。
                  : (_viewMode.state == ViewState.control ? _bottomBar(wide) : _viewToolbar()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar(bool wide) {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
      decoration: const BoxDecoration(
        color: AppColors.videoChrome,
        border: Border(bottom: BorderSide(color: AppColors.videoChromeBorder)),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: '返回设备列表（Esc）',
            onPressed: _confirmExit,
            icon: const Icon(Icons.arrow_back, size: 20),
          ),
          StatusDot(
            color: _statusColor(),
            pulse: _transport != null && !_stalled,
            size: 7,
          ),
          const SizedBox(width: AppSpace.sm),
          // 设备名必须优先保住：Expanded 前面的固定宽度元素一多，
          // 窄屏（390px）里这段会被压成 0，用户就看不出在控哪台机器。
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  widget.device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // 必须显式给色：不写就继承浅色主题的深色文字，
                  // 压在 videoChrome 深底上等于隐形（之前「设备名消失」的真因）。
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                    color: AppColors.videoText,
                  ),
                ),
                Text(
                  _statusText(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: _statusColor(), height: 1.3),
                ),
              ],
            ),
          ),
          // 窄屏只留图标，省下的宽度给设备名；屏数与名称进 tooltip / 菜单
          _screenSelector(compact: !wide),
          _qualitySelector(compact: !wide),
          // 宽屏才把安全/电源/信息/全屏放顶栏；窄屏全部收进「更多」，
          // 否则 46px 高、390px 宽的条里塞 8 个控件必然互相挤压。
          if (wide) ...<Widget>[
            _iconBtn(
              tooltip: _security.protectedNow ? '安全：已防护' : '安全：需关注',
              onPressed: _openSecurityPanel,
              icon: Icon(
                _security.protectedNow ? Icons.shield : Icons.shield_outlined,
                size: 19,
                color: _security.protectedNow ? AppColors.online : AppColors.videoMuted,
              ),
            ),
            _iconBtn(
              tooltip: '电源',
              onPressed: _openPowerPanel,
              icon: const Icon(Icons.power_settings_new, size: 19),
            ),
            _iconBtn(
              tooltip: '连接信息',
              onPressed: _showInfo,
              icon: const Icon(Icons.info_outline, size: 19),
            ),
            _iconBtn(
              tooltip: _fullscreen ? '退出全屏（F11）' : '全屏（F11）',
              onPressed: () => _setFullscreen(!_fullscreen),
              icon: Icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, size: 20),
            ),
          ],
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (String v) {
              if (v == 'reconnect') _reconnect();
              if (v == 'clip') _toggleClipboardSync();
              if (v == 'hud') setState(() => _showHud = !_showHud);
              if (v == 'info') _showInfo();
              if (v == 'security') _openSecurityPanel();
              if (v == 'power') _openPowerPanel();
              if (v == 'fullscreen') _setFullscreen(!_fullscreen);
              if (v == 'viewmode') {
                _setViewState(
                  _viewMode.state == ViewState.control ? ViewState.view : ViewState.control,
                );
              }
              if (v == 'annotation') _toggleAnnotation();
              if (v == 'shortcuts') _openShortcuts();
              if (v == 'mini') _openMiniWindowPanel();
              if (v == 'close') _confirmExit();
            },
            itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'viewmode',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _viewMode.state == ViewState.control
                        ? Icons.visibility_outlined
                        : Icons.touch_app,
                    size: 18,
                    color: _viewMode.state == ViewState.control
                        ? AppColors.videoMuted
                        : AppColors.accent,
                  ),
                  title: Text(
                    _viewMode.state == ViewState.control ? '观看模式（输入不发送）' : '回到操控模式',
                  ),
                ),
              ),
              PopupMenuItem<String>(
                value: 'annotation',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.edit_outlined,
                    size: 18,
                    color: _viewMode.state == ViewState.annotation
                        ? AppColors.accent
                        : AppColors.videoMuted,
                  ),
                  title: Text(
                    _viewMode.state == ViewState.annotation ? '退出批注' : '批注（只在本机可见）',
                  ),
                ),
              ),
              if (_isDesktop)
                PopupMenuItem<String>(
                  value: 'mini',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _mini.enabled ? Icons.close_fullscreen : Icons.picture_in_picture_alt,
                      size: 18,
                      color: _mini.enabled ? AppColors.accent : AppColors.videoMuted,
                    ),
                    title: Text(_mini.enabled ? '退出小窗模式' : '小窗模式（置顶浮窗）'),
                  ),
                ),
              const PopupMenuDivider(height: 1),
              PopupMenuItem<String>(
                value: 'hud',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _showHud ? Icons.visibility : Icons.visibility_off_outlined,
                    size: 18,
                    color: _showHud ? AppColors.accent : AppColors.videoMuted,
                  ),
                  title: Text(_showHud ? '网络状态：显示' : '网络状态：隐藏'),
                ),
              ),
              PopupMenuItem<String>(
                value: 'clip',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _clip.enabled ? Icons.content_paste : Icons.content_paste_off,
                    size: 18,
                    color: _clip.enabled ? AppColors.online : AppColors.videoMuted,
                  ),
                  title: Text(_clip.enabled ? '剪贴板同步：开' : '剪贴板同步：关'),
                ),
              ),
              const PopupMenuDivider(height: 1),
              const PopupMenuItem<String>(
                value: 'reconnect',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.refresh, size: 18, color: AppColors.videoMuted),
                  title: Text('重新连接'),
                ),
              ),
              const PopupMenuItem<String>(
                value: 'shortcuts',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.keyboard_outlined, size: 18, color: AppColors.videoMuted),
                  title: Text('快捷键设置'),
                ),
              ),
              if (!wide) ...<PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'security',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _security.protectedNow ? Icons.shield : Icons.shield_outlined,
                      size: 18,
                      color: _security.protectedNow ? AppColors.online : AppColors.videoMuted,
                    ),
                    title: const Text('安全与隐私'),
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'power',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.power_settings_new, size: 18, color: AppColors.videoMuted),
                    title: Text('电源'),
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'info',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.info_outline, size: 18, color: AppColors.videoMuted),
                    title: Text('连接信息'),
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'fullscreen',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      size: 18,
                      color: AppColors.videoMuted,
                    ),
                    title: Text(_fullscreen ? '退出全屏' : '全屏'),
                  ),
                ),
              ],
              const PopupMenuDivider(height: 1),
              const PopupMenuItem<String>(
                value: 'close',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.link_off, size: 18, color: AppColors.danger),
                  title: Text('断开连接', style: TextStyle(color: AppColors.danger)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 顶栏图标按钮：34px 见方。窄屏上 5 个 48px 的 IconButton 一定溢出，
  /// 这里统一收窄，触控区仍靠 Tooltip + InkResponse 的溅射补足。
  Widget _iconBtn({
    required String tooltip,
    required VoidCallback onPressed,
    required Widget icon,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: 20,
        containedInkWell: false,
        child: SizedBox(width: 34, height: 34, child: Center(child: icon)),
      ),
    );
  }

  /// 网络状态指标。顶栏不再常驻（会把设备名挤没），改由 [_hudOverlay] 叠加在画面左上角。
  List<Widget> _hudChips() {
    final AgentHello? hello = _hello;
    final MediaTransport? transport = _transport;
    if (transport == null) return const <Widget>[];
    final bool webRtc = transport.kind == 'webrtc';

    if (webRtc) {
      // 协议 §7 要求的 HUD：编码 · 实际 fps · 实际分辨率（来自 getStats）。
      // fps 还没统计到（未收到首帧）时显示 —，不要显示 0 fps 让人以为卡住。
      final int? fps = _stats.fps;
      final int w = _stats.width > 0 ? _stats.width : (hello?.width ?? 0);
      final int h = _stats.height > 0 ? _stats.height : (hello?.height ?? 0);
      final int? bitrate = _stats.bitrateKbps;
      return <Widget>[
        HudChip(
          text: '${fps == null ? '—' : '$fps fps'} · $w×$h',
          icon: Icons.aspect_ratio,
          color: fps == null
              ? AppColors.videoMuted
              : (fps >= 24 ? AppColors.accentHover : AppColors.warn),
        ),
        HudChip(
          text: 'H.264${bitrate == null ? '' : ' · $bitrate kbps'}',
          icon: Icons.bolt,
          color: AppColors.videoMuted,
        ),
        if (_stats.rttMs != null)
          HudChip(
            text: 'RTT ${_stats.rttMs}ms',
            icon: Icons.network_ping,
            color: _stats.rttMs! < 80
                ? AppColors.accentHover
                : (_stats.rttMs! < 180 ? AppColors.warn : AppColors.danger),
          ),
        if (_stats.lossPercent != null)
          HudChip(
            text: '丢包 ${_stats.lossPercent!.toStringAsFixed(1)}%',
            icon: Icons.signal_cellular_alt,
            color: _stats.lossPercent! < 1
                ? AppColors.videoMuted
                : (_stats.lossPercent! < 5 ? AppColors.warn : AppColors.danger),
          ),
        // 只有 hello.audio 为真且真的收到音频轨才显示（缺音频不影响视频）
        if ((hello?.audio ?? false) && _audioAvailable)
          HudChip(
            text: _audioMuted ? '静音' : '有声',
            icon: _audioMuted ? Icons.volume_off : Icons.volume_up,
            color: _audioMuted ? AppColors.videoMuted : AppColors.accentHover,
          ),
      ];
    }

    // JPEG 兜底：没有 getStats，改用本地统计。首帧未到前 _fps 恒 0，
    // 显示「—」而不是「0 fps」——后者看起来像编码器卡死。
    final bool hasFrame = _lastFrameAt != null;
    return <Widget>[
      HudChip(
        text: hasFrame ? '$_fps fps' : '— fps',
        icon: Icons.speed,
        color: hasFrame && _fps >= 24 ? AppColors.accentHover : AppColors.videoMuted,
      ),
      if (hello != null && hello.width > 0)
        HudChip(text: '${hello.width}×${hello.height}', icon: Icons.aspect_ratio),
      if (_latency > Duration.zero)
        HudChip(
          text: '${_latency.inMilliseconds}ms',
          icon: Icons.network_ping,
          color: _latency.inMilliseconds < 80
              ? AppColors.accentHover
              : (_latency.inMilliseconds < 180 ? AppColors.warn : AppColors.danger),
        ),
      HudChip(
        text: transport.kind == 'jpeg' ? 'JPEG 兜底' : 'H.264',
        icon: transport.kind == 'jpeg' ? Icons.warning_amber_rounded : Icons.bolt,
        color: transport.kind == 'jpeg' ? AppColors.warn : AppColors.accentHover,
      ),
    ];
  }

  /// 画面左上角的网络状态浮层（官方 netInfo）：只在用户主动打开时出现，
  /// 不占顶栏空间。窄屏用 Wrap 换行，避免一行挤爆。
  Widget _hudOverlay() {
    final List<Widget> chips = _hudChips();
    if (chips.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.videoChromeBorder),
        ),
        constraints: const BoxConstraints(maxWidth: 420),
        child: Wrap(
          spacing: AppSpace.md,
          runSpacing: 3,
          children: chips,
        ),
      ),
    );
  }

  /// 显示屏下拉（协议 v2 §3）：多屏时切换，单屏时按官方文案说明无需切换。
  ///
  /// [compact] 为窄屏形态：只留图标不带「1/2」文字，把宽度让给设备名。
  Widget _screenSelector({bool compact = false}) {
    final bool multi = _screens.length > 1;
    final String text = multi ? '${_screens.indexWhere((ScreenInfo s) => s.id == _screenId) + 1}/${_screens.length}' : '1/1';
    return PopupMenuButton<int>(
      tooltip: multi ? '切换显示屏（$text）' : '当前只有 1 个屏幕',
      onSelected: _selectScreen,
      color: AppColors.videoChrome,
      position: PopupMenuPosition.under,
      itemBuilder: (BuildContext ctx) {
        if (!multi) {
          return const <PopupMenuEntry<int>>[
            PopupMenuItem<int>(
              enabled: false,
              child: Text('当前远程窗口仅有 1 个屏幕，无需切换',
                  style: TextStyle(fontSize: 12, color: AppColors.videoMuted)),
            ),
          ];
        }
        return _screens
            .map((ScreenInfo s) => PopupMenuItem<int>(
                  value: s.id,
                  child: Row(
                    children: <Widget>[
                      Icon(
                        s.id == _screenId ? Icons.check_circle : Icons.desktop_windows_outlined,
                        size: 15,
                        color: s.id == _screenId ? AppColors.accent : AppColors.videoMuted,
                      ),
                      const SizedBox(width: AppSpace.sm),
                      Text(s.label,
                          style: TextStyle(
                            fontSize: 12,
                            color: s.id == _screenId ? AppColors.videoText : AppColors.videoMuted,
                          )),
                    ],
                  ),
                ))
            .toList();
      },
      child: Container(
        height: 26,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: compact ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 8),
        width: compact ? 30 : null,
        decoration: BoxDecoration(
          color: AppColors.videoBg,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: compact && multi ? AppColors.accent.withValues(alpha: 0.6) : AppColors.videoChromeBorder,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(multi ? Icons.desktop_windows : Icons.desktop_windows_outlined,
                size: 14, color: multi ? AppColors.videoText : AppColors.videoMuted),
            if (!compact) ...<Widget>[
              const SizedBox(width: 5),
              Text(text,
                  style: TextStyle(
                    fontSize: 11,
                    color: multi ? AppColors.videoText : AppColors.videoMuted,
                    fontWeight: FontWeight.w500,
                  )),
            ],
          ],
        ),
      ),
    );
  }

  /// 顶栏画质入口：显示当前档位 + 帧率，点开完整面板（官方 B2.2）。
  ///
  /// [compact] 为窄屏形态：只显示档位名（「超清」），省掉「· 60fps」约 30px。
  Widget _qualitySelector({bool compact = false}) {
    return InkWell(
      onTap: _openQualityPanel,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        height: 26,
        margin: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: AppColors.videoBg,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.videoChromeBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.tune, size: 14, color: AppColors.videoMuted),
            const SizedBox(width: 5),
            Text(
              compact ? _quality.preset.label : _quality.label,
              style: const TextStyle(fontSize: 11, color: AppColors.videoText),
            ),
            const Icon(Icons.expand_more, size: 14, color: AppColors.videoMuted),
          ],
        ),
      ),
    );
  }

  /// 打开画质面板（官方 B2.2）。改一项即时下发，不等「确定」。
  Future<void> _openQualityPanel() async {
    await showQualityPanel(
      context,
      prefs: _quality,
      agentMaxFps: _hello?.maxFps ?? 60,
      onChanged: (StreamPrefs next) {
        if (!mounted) return;
        setState(() => _quality = next);
        unawaited(Settings.saveStreamPrefs(next));
        // 拖码率滑块会连发几十次，防抖后只下发最后一拍（Agent 侧重建编码器不便宜）
        _qualityDebounce?.cancel();
        _qualityDebounce = Timer(const Duration(milliseconds: 180), _applyQuality);
      },
    );
  }

  /// 底部工具条：常用远控操作，全屏时会自动隐藏。
  Widget _bottomBar(bool wide) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
      decoration: const BoxDecoration(
        color: AppColors.videoChrome,
        border: Border(top: BorderSide(color: AppColors.videoChromeBorder)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  ToolButton(
                    icon: _keyboardLock ? Icons.keyboard_alt : Icons.keyboard_hide_outlined,
                    // 窄屏 390px 放不下 6 个带长标签的按钮，这里只压缩这两个：
                    // 「键盘」保留文字（状态色已能表达开关），Ctrl+Alt+Del 退成纯图标
                    label: wide ? (_keyboardLock ? '键盘已接管' : '键盘已暂停') : '键盘',
                    tooltip: _keyboardLock
                        ? '键盘已接管：按键会发给被控端，点击暂停'
                        : '键盘已暂停：按键只作用于本机，点击接管',
                    active: _keyboardLock,
                    onPressed: () => setState(() => _keyboardLock = !_keyboardLock),
                  ),
                  if ((_hello?.audio ?? false) && _audioAvailable)
                    ToolButton(
                      icon: _audioMuted ? Icons.volume_off : Icons.volume_up,
                      label: _audioMuted ? '已静音' : '声音',
                      tooltip: _audioMuted ? '点击开启被控端声音' : '静音（仅本机，不通知被控端）',
                      active: !_audioMuted,
                      onPressed: _toggleAudio,
                    ),
                  ToolButton(
                    icon: Icons.content_paste,
                    label: '粘贴',
                    tooltip: '粘贴本机剪贴板（⌘/Ctrl+V）',
                    onPressed: _sendClipboardText,
                  ),
                  ToolButton(
                    // 原来用 Icons.security（盾牌），和安全/防窥入口撞语义
                    icon: Icons.keyboard_command_key,
                    label: wide ? 'Ctrl+Alt+Del' : null,
                    tooltip: '向被控端发送 Ctrl+Alt+Del（打开任务管理器）',
                    onPressed: () {
                      _send(<String, dynamic>{'p': 'input', 't': 'key', 'combo': <String>['ctrl', 'alt', 'delete']});
                    },
                  ),
                  const _Divider(),
                  // 全屏只在顶栏（宽屏）与「更多」菜单（窄屏）出现，底栏不再重复
                  ToolButton(
                    icon: Icons.refresh,
                    label: '重连',
                    tooltip: '重新连接（⌘/Ctrl+F5）',
                    onPressed: _reconnect,
                  ),
                  ToolButton(
                    icon: Icons.link_off,
                    label: '断开',
                    tooltip: '断开并返回设备列表',
                    danger: true,
                    onPressed: _confirmExit,
                  ),
                ],
              ),
            ),
          ),
          if (wide) _inputHint(),
        ],
      ),
    );
  }

  Widget _inputHint() {
    final bool touch = !_isDesktop;
    return Padding(
      padding: const EdgeInsets.only(left: AppSpace.sm),
      child: Text(
        touch ? '轻点左键 · 长按右键 · 双指滚动' : '⌘/Ctrl+V 粘贴 · F11 全屏 · 右键=右键菜单',
        style: const TextStyle(color: AppColors.videoMuted, fontSize: 10.5),
      ),
    );
  }

  /// 观看/批注态的底部工具条（官方 B4）。
  Widget _viewToolbar() {
    if (!_viewMode.toolbarVisible) {
      // 隐藏后必须留一个可见的唤回入口，否则用户只能靠背快捷键找回来。
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 2),
        decoration: const BoxDecoration(
          color: AppColors.videoChrome,
          border: Border(top: BorderSide(color: AppColors.videoChromeBorder)),
        ),
        child: Center(
          child: TextButton.icon(
            onPressed: () =>
                setState(() => _viewMode = _viewMode.copyWith(toolbarVisible: true)),
            icon: const Icon(Icons.keyboard_arrow_up, size: 15, color: AppColors.videoMuted),
            label: const Text(
              '显示观看工具条',
              style: TextStyle(fontSize: 11, color: AppColors.videoMuted),
            ),
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
      decoration: const BoxDecoration(
        color: AppColors.videoChrome,
        border: Border(top: BorderSide(color: AppColors.videoChromeBorder)),
      ),
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ViewToolbar(
            state: _viewMode.state,
            scale: _viewMode.transform.scale,
            annotationFull: _annotations.strokes.length >= AnnotationBoard.maxStrokes,
            onToggleAnnotation: _toggleAnnotation,
            onZoomIn: () => _zoomBy(1.25),
            onZoomOut: () => _zoomBy(1 / 1.25),
            onResetZoom: _resetZoom,
            onExitView: () => _setViewState(ViewState.control),
            onHide: () =>
                setState(() => _viewMode = _viewMode.copyWith(toolbarVisible: false)),
          ),
        ),
      ),
    );
  }

  /// 退出远控（官方 B9 第 3 条：会话进行中要二次确认，避免误触断开）。
  /// 未连上时直接返回，不打扰。
  Future<void> _confirmExit() async {
    final bool live = _transport != null || _signaling?.isOpen == true;
    if (!live) {
      Navigator.of(context).maybePop();
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('结束远程控制？'),
        content: const Text('断开后本次会话结束，需要重新连接才能继续操作被控端。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('继续控制')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('断开', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // 主动退出不算故障：先停掉自动重连，否则刚断开就被退避策略拉回去
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectPolicy.reset();
    await _detach();
    if (mounted) Navigator.of(context).maybePop();
  }

  String _statusText() {
    if (_connecting) return _progress.stage.label;
    if (_error != null) return '连接失败';
    if (_transport == null) {
      return _signaling?.isOpen == true ? '信令已连接，等待被控端 hello' : '信令未连接';
    }
    if (_reconnectIn > 0) return '$_reconnectIn 秒后自动重连…';
    if (_stalled) {
      return _reconnectPolicy.exhausted ? '画面中断（自动重连已停止）' : '画面中断，等待新帧…';
    }
    final AgentHello? hello = _hello;
    if (hello == null) return '已连接';
    final bool webRtc = _transport?.kind == 'webrtc';
    // 上一行已经是设备名，这里不再重复 hello.name，只留系统与通路
    return '实时 · ${hello.os} · ${webRtc ? 'WebRTC 直连' : 'JPEG 兜底'}';
  }

  Color _statusColor() {
    if (_error != null) return AppColors.danger;
    if (_reconnectIn > 0 || _stalled) return AppColors.warn;
    if (_transport != null) return AppColors.accent;
    return AppColors.videoMuted;
  }

  Widget _stage() {
    // 连接期也走 7 阶段视图：官方等待页从「正在连接服务器」就开始分步显示，
    // 比一句「正在加入房间并连接信令…」更能说明卡在哪。
    if (_connecting) return _waitingView();
    final String? error = _error;
    if (error != null) return _errorView(error);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size box = Size(constraints.maxWidth, constraints.maxHeight);
        // 记给键盘缩放用（build 期间改字段不触发重建，安全）
        _stageSize = box;
        // 观看态拦截输入：hover/滚轮/按键都不再发给被控端
        final bool intercept = _viewMode.state.interceptsInput;
        return Focus(
          focusNode: _focusNode,
          autofocus: true,
          // 失焦兜底：按住 Shift/Alt/Ctrl/Cmd 时切走窗口，那次 keyUp 永远到不了
          // onKeyEvent，不补发就会把修饰键「粘」在远端
          onFocusChange: (bool hasFocus) {
            if (!hasFocus) _releaseHeldMods();
          },
          onKeyEvent: (FocusNode node, KeyEvent event) {
            _handleKey(event);
            return KeyEventResult.handled;
          },
          child: Listener(
            behavior: HitTestBehavior.opaque,
            // 观看态下 hover 会持续把「鼠标在动」发给被控端，那等于没拦截。
            onPointerHover: intercept ? null : (PointerHoverEvent e) => _sendMove(e.localPosition, box),
            onPointerDown: (PointerDownEvent e) => _onPointerDown(e, box),
            onPointerMove: (PointerMoveEvent e) => _onPointerMove(e, box),
            onPointerUp: (PointerUpEvent e) => _onPointerUp(e, box),
            onPointerCancel: (PointerCancelEvent e) {
              _longPress?.cancel();
              _downAt = null;
              _downTime = null;
              _dragged = false;
              _longPressFired = false;
              _panLast = null;
              if (_viewMode.state == ViewState.annotation) {
                _annotations.end();
                if (mounted) setState(() {});
              }
            },
            onPointerSignal: intercept ? null : _onPointerSignal,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ColoredBox(color: Colors.black, child: _buildScaled(box)),
                // 批注层画在画面之上、所有浮层之下
                if (_viewMode.state == ViewState.annotation)
                  AnnotationLayer(
                    board: _annotations,
                    revision: _annotations.revision,
                  ),
                // 网络状态浮层（官方 netInfo）：放左上角，避开顶部居中的倒计时条
                if (_showHud && _transport != null)
                  Positioned(
                    left: AppSpace.md,
                    top: AppSpace.md,
                    child: _hudOverlay(),
                  ),
                // 观看/批注态顶部提示条：明确告诉用户「输入不会过去」
                if (_viewMode.state != ViewState.control)
                  Positioned(
                    top: AppSpace.md,
                    left: 0,
                    right: 0,
                    child: Center(child: ViewModeHint(state: _viewMode.state)),
                  ),
                // 批注工具（颜色/撤销/清空）单独浮一条，避免和观看工具条挤在一起
                if (_viewMode.state == ViewState.annotation)
                  Positioned(
                    top: AppSpace.md + 28,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: GlassPanel(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 3),
                        child: AnnotationBar(
                          color: _penColor,
                          strokeCount: _annotations.strokes.length,
                          canUndo: _annotations.strokes.isNotEmpty,
                          onColor: (Color c) => setState(() => _penColor = c),
                          onUndo: () {
                            _annotations.undo();
                            setState(() {});
                          },
                          onClear: () {
                            _annotations.clear();
                            setState(() {});
                          },
                        ),
                      ),
                    ),
                  ),
                // 被控端明确报错（如没屏/缺授权）优先于「中断」提示：转圈解决不了问题
                if (_agentError != null)
                  _noticeOverlay(_agentError!)
                else if (_stalled)
                  _stalledOverlay(),
                if (_countdown != null)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: PowerCountdownBanner(
                        countdown: _countdown!,
                        onCancel: _cancelPower,
                      ),
                    ),
                  ),
                // 工具栏收起时，上下两条热区负责唤出（官方：鼠标移到顶部/边缘）
                if (!_chromeVisible) ...<Widget>[
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: 44,
                    child: MouseRegion(onEnter: (_) => _pokeChrome(), child: const SizedBox.expand()),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 44,
                    child: MouseRegion(onEnter: (_) => _pokeChrome(), child: const SizedBox.expand()),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// 应用观看模式的缩放/平移。`identity` 时直接返回原画面，
  /// 避免每帧都套一层 Transform（JPEG 通路上这层会额外拷一次位图）。
  Widget _buildScaled(Size box) {
    final ViewTransform transform = _viewMode.transform;
    if (transform.isIdentity) return _buildVideo();
    return ClipRect(
      child: Transform(
        alignment: Alignment.topLeft,
        transform: Matrix4.identity()
          ..translateByDouble(transform.offset.dx, transform.offset.dy, 0, 1)
          ..scaleByDouble(transform.scale, transform.scale, 1, 1),
        child: _buildVideo(),
      ),
    );
  }

  Widget _buildVideo() {
    final MediaTransport? transport = _transport;
    if (transport == null) {
      return _waitingView();
    }
    // 画面（JPEG 的 Image.memory / WebRTC 的 RTCVideoView）都挂在 _stage 里那层
    // Listener 之下，因此鼠标/触摸事件的 localPosition 与归一化几何完全一致：
    // 换通路不需要改坐标换算（协议 §6：x/y ∈ [0,1] 不变）。
    return transport.buildView(fit: BoxFit.contain);
  }

  /// 首帧未到：给出分阶段提示，而不是一直转圈。
  Widget _waitingView() {
    final ConnectStage stage = _progress.stage;
    final bool signalingUp = _signaling?.isOpen == true;
    // 进房成功但还没收到 hello：阶段停在 syncInfo，补一句更具体的等待对象
    final String hint = signalingUp && stage == ConnectStage.syncInfo
        ? '已进入房间，等待被控端发送 agent.hello'
        : stage.hint;
    return Center(
      child: GlassPanel(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl, vertical: AppSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(height: AppSpace.md),
            Text(
              stage.label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11.5, color: AppColors.videoMuted, height: 1.5),
            ),
            const SizedBox(height: AppSpace.md),
            // 7 阶段进度条：让「卡住了」和「在走」一眼可分
            SizedBox(
              width: 180,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: _progress.ratio,
                  minHeight: 3,
                  backgroundColor: AppColors.videoChromeBorder,
                  valueColor: const AlwaysStoppedAnimation<Color>(AppColors.info),
                ),
              ),
            ),
            if (_reconnectIn > 0) ...<Widget>[
              const SizedBox(height: AppSpace.sm),
              Text(
                '$_reconnectIn 秒后自动重连',
                style: const TextStyle(fontSize: 11, color: AppColors.warn),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stalledOverlay() {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpace.lg),
        child: GlassPanel(
          borderColor: AppColors.warn.withValues(alpha: 0.5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.wifi_off, size: 15, color: AppColors.warn),
              const SizedBox(width: AppSpace.sm),
              Text(
                _reconnectIn > 0
                    ? '画面中断，$_reconnectIn 秒后自动重连'
                    : _reconnectPolicy.exhausted
                        ? '画面中断，自动重连已停止'
                        : '画面中断，等待新帧…',
                style: const TextStyle(color: AppColors.warn, fontSize: 12),
              ),
              const SizedBox(width: AppSpace.md),
              InkWell(
                onTap: _reconnect,
                child: const Text('立即重连', style: TextStyle(color: AppColors.info, fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 被控端主动报错（如 `screen_permission`）：常驻一条，带重连入口。
  Widget _noticeOverlay(String text) {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpace.lg),
        child: GlassPanel(
          borderColor: AppColors.danger.withValues(alpha: 0.45),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline, size: 15, color: AppColors.danger),
              const SizedBox(width: AppSpace.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(text, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
              ),
              const SizedBox(width: AppSpace.md),
              InkWell(
                onTap: _reconnect,
                child: const Text('重连', style: TextStyle(color: AppColors.info, fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorView(String message) {
    // 失败视图要能回答「还用不用我动手」：倒计时中说明会自动重试，
    // 退避耗尽才把皮球踢回用户，避免用户白等。
    final String detail = _reconnectIn > 0
        ? '$message\n\n$_reconnectIn 秒后自动重连'
        : _reconnectPolicy.exhausted
            ? '$message\n\n自动重连已停止，请手动重连'
            : message;
    return EmptyState(
      icon: Icons.link_off,
      title: '连接失败',
      message: detail,
      action: Column(
        children: <Widget>[
          ElevatedButton.icon(
            onPressed: _reconnect,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重新连接'),
          ),
          const SizedBox(height: AppSpace.sm),
          TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('返回设备列表')),
        ],
      ),
    );
  }
}

/// `agent.error` 的已知错误码 → 中文说明（`p:"agent.error", err:"..."`）。
///
/// 未知码原样透出，别静默吞掉——联调时要能看到 Agent 到底报了什么。
String describeAgentError(Object? code) {
  switch ('$code') {
    case 'screen_permission':
      return '被控端没有可用屏幕：显示器已关闭或缺少屏幕录制授权';
    case 'audio_unavailable':
      return '被控端音频不可用（麦克风/系统声音打不开），画面不受影响';
    default:
      return '被控端错误：$code';
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
      color: AppColors.videoChromeBorder,
    );
  }
}