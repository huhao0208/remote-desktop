import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/input_events.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../media/jpeg_transport.dart';
import '../media/media_factory.dart';
import '../media/media_transport.dart';
import '../media/webrtc_transport.dart';
import '../signaling/signaling_client.dart';
import '../widgets/ui_kit.dart';

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

  bool _connecting = true;
  String? _error;

  /// `agent.error` 的可读说明，常驻在画面区顶部（清空条件：新 hello / 重连）。
  String? _agentError;
  bool _stalled = false;
  bool _applyingHello = false;

  bool _fullscreen = false;
  bool _chromeVisible = true;
  bool _keyboardLock = true;

  QualityPreset _quality = AppConfig.qualityPresets[AppConfig.defaultQualityIndex];
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

  bool get _isDesktop => !(Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    _api = ApiClient(baseUrl: Settings.serverBase);
    _quality = _resolvePreset(QualityPreset.fromValue(Settings.qualityValue).value);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    _connect();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _chromeTimer?.cancel();
    _longPress?.cancel();
    _msgSub?.cancel();
    _frameSub?.cancel();
    // 释放被控端可能还按着的修饰键，避免对端「卡键」
    for (final String mod in _heldMods) {
      _signaling?.sendJson(InputEvent.keyUp(mod));
    }
    _heldMods.clear();
    // 退出页面时若仍在全屏，恢复窗口，避免把整个 App 卡在全屏
    if (_fullscreen) _setFullscreen(false);
    _statsListenable?.removeListener(_onStats);
    _statsListenable = null;
    _transport?.dispose();
    _signaling?.close();
    _api.close();
    _focusNode.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 连接

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
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
      setState(() => _connecting = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = e.toString();
      });
    }
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
  }

  Future<void> _reconnect() async {
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
      case 'stream.config.ack':
        final Object? w = message['width'];
        final Object? f = message['fps'];
        final Object? br = message['bitrate'];
        _toast('画质已切换：${w}px · ${f}fps${br == null ? '' : ' · ${br}kbps'}');
      case 'shutdown.state':
        _toast('关机状态：${message['state']}');
      case 'agent.error':
        _onAgentError(message['err']);
      default:
        break;
    }
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
      if (hello.width > 0 && hello.height > 0) {
        _screen = Size(hello.width.toDouble(), hello.height.toDouble());
      }
    });
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
    if (!mounted) return;
    setState(() => _stats = stats);
  }

  void _applyQuality() {
    final SignalingClient? signaling = _signaling;
    if (signaling == null || !signaling.isOpen || _hello == null) return;
    signaling.sendJson(InputEvent.streamConfig(
      width: _quality.width,
      quality: _quality.quality,
      fps: _hello!.fps > 0 ? _hello!.fps : 30,
      bitrate: _quality.bitrate,
    ));
  }

  void _onFrame(FramePacket packet) {
    _framesInWindow++;
    _lastFrameAt = DateTime.now();
    _latency = packet.latency;
    if (!mounted) return;
    if (_stalled) setState(() => _stalled = false);
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
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  // ------------------------------------------------------------ 桌面外壳

  /// 全屏切换。桌面走 window_manager，移动端走系统沉浸式。
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
    if (on) _scheduleChromeHide();
  }

  /// 全屏时鼠标静止一会儿自动收起工具栏，把画面让出来。
  void _scheduleChromeHide() {
    _chromeTimer?.cancel();
    if (!_fullscreen) return;
    _chromeTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _chromeVisible = false);
    });
  }

  void _pokeChrome() {
    if (!_fullscreen) return;
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
    if (event.buttons == kSecondaryMouseButton) {
      final Offset p = _normalize(event.localPosition, box);
      _send(InputEvent.click(p.dx, p.dy, btn: 'right'));
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
    _pokeChrome();
    final Offset? down = _downAt;
    if (down != null && (event.localPosition - down).distance > 6) {
      _dragged = true;
      _longPress?.cancel();
    }
    _sendMove(event.localPosition, box);
  }

  void _onPointerUp(PointerUpEvent event, Size box) {
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

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      // 与 control.html 一致：滚轮向上（deltaY<0）→ dy=3
      _send(InputEvent.scroll(event.scrollDelta.dy < 0 ? 3 : -3));
    }
  }

  /// 快捷键先拦截本机操作，再透传给被控端。
  bool _handleShortcut(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final bool ctrl = HardwareKeyboard.instance.isControlPressed;
    final bool meta = HardwareKeyboard.instance.isMetaPressed;
    final bool alt = HardwareKeyboard.instance.isAltPressed;
    final LogicalKeyboardKey key = event.logicalKey;

    if (key == LogicalKeyboardKey.f11) {
      _setFullscreen(!_fullscreen);
      return true;
    }
    if (key == LogicalKeyboardKey.escape && _fullscreen) {
      _setFullscreen(false);
      return true;
    }
    if ((ctrl || meta) && !alt && (key == LogicalKeyboardKey.keyV)) {
      _sendClipboardText();
      return true;
    }
    if ((ctrl || meta) && key == LogicalKeyboardKey.f5) {
      _reconnect();
      return true;
    }
    return false;
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
              child: (_fullscreen && !_chromeVisible) ? const SizedBox(width: double.infinity) : _topBar(wide),
            ),
            Expanded(child: _stage()),
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              child: (_fullscreen && !_chromeVisible)
                  ? const SizedBox(width: double.infinity)
                  : _bottomBar(wide),
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
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back, size: 20),
          ),
          StatusDot(
            color: _statusColor(),
            pulse: _transport != null && !_stalled,
            size: 7,
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  widget.device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.2),
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
          if (wide) ..._hud(),
          _qualitySelector(),
          IconButton(
            tooltip: _fullscreen ? '退出全屏（F11）' : '全屏（F11）',
            onPressed: () => _setFullscreen(!_fullscreen),
            icon: Icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, size: 20),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (String v) {
              if (v == 'reconnect') _reconnect();
              if (v == 'close') Navigator.of(context).maybePop();
            },
            itemBuilder: (BuildContext ctx) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'reconnect',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.refresh, size: 18, color: AppColors.videoMuted),
                  title: Text('重新连接'),
                ),
              ),
              PopupMenuItem<String>(
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

  List<Widget> _hud() {
    final AgentHello? hello = _hello;
    final bool webRtc = _transport?.kind == 'webrtc';
    if (webRtc) {
      // 协议 §7 要求的 HUD：编码 · 实际 fps · 实际分辨率（来自 getStats）。
      // fps 还没统计到（未收到首帧）时显示 —，不要显示 0 fps 让人以为卡住。
      final int? fps = _stats.fps;
      final int w = _stats.width > 0 ? _stats.width : (hello?.width ?? 0);
      final int h = _stats.height > 0 ? _stats.height : (hello?.height ?? 0);
      return <Widget>[
        HudChip(
          text: 'H.264 · ${fps == null ? '—' : '$fps fps'} · $w×$h',
          icon: Icons.bolt,
          color: fps == null
              ? AppColors.videoMuted
              : (fps >= 24 ? AppColors.accentHover : AppColors.warn),
        ),
        // 只有 hello.audio 为真且真的收到音频轨才显示（缺音频不影响视频）
        if ((hello?.audio ?? false) && _audioAvailable)
          HudChip(
            text: _audioMuted ? '静音' : '有声',
            icon: _audioMuted ? Icons.volume_off : Icons.volume_up,
            color: _audioMuted ? AppColors.videoMuted : AppColors.accentHover,
          ),
        const SizedBox(width: AppSpace.xs),
      ];
    }
    return <Widget>[
      HudChip(text: '$_fps fps', icon: Icons.speed, color: _fps >= 24 ? AppColors.accentHover : AppColors.videoMuted),
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
      if (_transport != null)
        HudChip(
          text: _transport!.kind == 'jpeg' ? 'JPEG 兜底' : 'H.264',
          icon: _transport!.kind == 'jpeg' ? Icons.warning_amber_rounded : Icons.bolt,
          color: _transport!.kind == 'jpeg' ? AppColors.warn : AppColors.accentHover,
        ),
      const SizedBox(width: AppSpace.xs),
    ];
  }

  Widget _qualitySelector() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: AppColors.videoBg,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.videoChromeBorder),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<QualityPreset>(
          value: _selectedPreset(),
          isDense: true,
          dropdownColor: AppColors.videoChrome,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          style: const TextStyle(fontSize: 11.5, color: AppColors.videoText),
          icon: const Icon(Icons.expand_more, size: 15, color: AppColors.videoMuted),
          items: AppConfig.qualityPresets
              .map((QualityPreset p) => DropdownMenuItem<QualityPreset>(
                    value: p,
                    child: Text(p.label),
                  ))
              .toList(),
          onChanged: (QualityPreset? preset) {
            if (preset == null) return;
            setState(() => _quality = preset);
            Settings.setQualityValue(preset.value);
            _applyQuality();
          },
        ),
      ),
    );
  }

  /// 把持久化档位对齐到预设列表里的实际对象（Dropdown 的 value 必须命中 items）。
  QualityPreset _resolvePreset(String value) {
    for (final QualityPreset p in AppConfig.qualityPresets) {
      if (p.value == value) return p;
    }
    return AppConfig.qualityPresets[AppConfig.defaultQualityIndex];
  }

  QualityPreset _selectedPreset() => _resolvePreset(_quality.value);

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
                    icon: Icons.keyboard_alt_outlined,
                    tooltip: _keyboardLock ? '键盘已接管（点击暂停）' : '键盘已暂停（点击接管）',
                    active: _keyboardLock,
                    onPressed: () => setState(() => _keyboardLock = !_keyboardLock),
                  ),
                  if ((_hello?.audio ?? false) && _audioAvailable)
                    ToolButton(
                      icon: _audioMuted ? Icons.volume_off : Icons.volume_up,
                      tooltip: _audioMuted ? '已静音（点击开启被控端声音）' : '静音（仅本机，不通知被控端）',
                      active: !_audioMuted,
                      onPressed: _toggleAudio,
                    ),
                  ToolButton(
                    icon: Icons.content_paste,
                    tooltip: '粘贴本机剪贴板（⌘/Ctrl+V）',
                    onPressed: _sendClipboardText,
                  ),
                  ToolButton(
                    icon: Icons.security,
                    tooltip: '发送 Ctrl+Alt+Del',
                    onPressed: () {
                      _send(<String, dynamic>{'p': 'input', 't': 'key', 'combo': <String>['ctrl', 'alt', 'delete']});
                    },
                  ),
                  const _Divider(),
                  ToolButton(
                    icon: Icons.fullscreen,
                    tooltip: '全屏（F11）',
                    active: _fullscreen,
                    onPressed: () => _setFullscreen(!_fullscreen),
                  ),
                  ToolButton(
                    icon: Icons.refresh,
                    tooltip: '重新连接（⌘/Ctrl+F5）',
                    onPressed: _reconnect,
                  ),
                  ToolButton(
                    icon: Icons.link_off,
                    tooltip: '断开并返回',
                    danger: true,
                    onPressed: () => Navigator.of(context).maybePop(),
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

  String _statusText() {
    if (_connecting) return '正在连接…';
    if (_error != null) return '连接失败';
    if (_transport == null) {
      return _signaling?.isOpen == true ? '信令已连接，等待被控端 hello' : '信令未连接';
    }
    if (_stalled) return '画面中断，等待新帧…';
    final AgentHello? hello = _hello;
    if (hello == null) return '已连接';
    final bool webRtc = _transport?.kind == 'webrtc';
    return '实时 · ${hello.name}（${hello.os}）· ${webRtc ? 'WebRTC 直连' : 'JPEG 兜底'}';
  }

  Color _statusColor() {
    if (_error != null) return AppColors.danger;
    if (_stalled) return AppColors.warn;
    if (_transport != null) return AppColors.accent;
    return AppColors.videoMuted;
  }

  Widget _stage() {
    if (_connecting) {
      return const LoadingView(text: '正在加入房间并连接信令…');
    }
    final String? error = _error;
    if (error != null) return _errorView(error);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size box = Size(constraints.maxWidth, constraints.maxHeight);
        return Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: (FocusNode node, KeyEvent event) {
            _handleKey(event);
            return KeyEventResult.handled;
          },
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerHover: (PointerHoverEvent e) => _sendMove(e.localPosition, box),
            onPointerDown: (PointerDownEvent e) => _onPointerDown(e, box),
            onPointerMove: (PointerMoveEvent e) => _onPointerMove(e, box),
            onPointerUp: (PointerUpEvent e) => _onPointerUp(e, box),
            onPointerCancel: (PointerCancelEvent e) {
              _longPress?.cancel();
              _downAt = null;
              _downTime = null;
              _dragged = false;
              _longPressFired = false;
            },
            onPointerSignal: _onPointerSignal,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ColoredBox(color: Colors.black, child: _buildVideo()),
                // 被控端明确报错（如没屏/缺授权）优先于「中断」提示：转圈解决不了问题
                if (_agentError != null)
                  _noticeOverlay(_agentError!)
                else if (_stalled)
                  _stalledOverlay(),
                // 全屏收起工具栏时，只有底部一小条热区负责唤出
                if (_fullscreen && !_chromeVisible)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 36,
                    child: MouseRegion(
                      onEnter: (_) => _pokeChrome(),
                      child: const SizedBox.expand(),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
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
    final bool signalingUp = _signaling?.isOpen == true;
    return Center(
      child: GlassPanel(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl, vertical: AppSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(height: AppSpace.md),
            Text(
              signalingUp ? '等待被控端画面…' : '信令未连接',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              signalingUp ? '已进入房间，等待 Agent 发送 agent.hello' : '点右上角重连，或检查服务端地址',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11.5, color: AppColors.videoMuted, height: 1.5),
            ),
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
              const Text('画面中断，等待新帧…', style: TextStyle(color: AppColors.warn, fontSize: 12)),
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
    return EmptyState(
      icon: Icons.link_off,
      title: '连接失败',
      message: message,
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