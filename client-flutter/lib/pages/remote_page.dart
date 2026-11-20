import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/input_events.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../media/jpeg_transport.dart';
import '../media/media_factory.dart';
import '../media/media_transport.dart';
import '../signaling/signaling_client.dart';

/// 远控页：加入房间 → 连信令 → 等 `agent.hello` → 渲染画面 + 转发输入。
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
  Timer? _ticker;

  bool _connecting = true;
  String? _error;
  bool _stalled = false;
  bool _applyingHello = false;

  QualityPreset _quality = AppConfig.qualityPresets[AppConfig.defaultQualityIndex];
  int _fps = 0;
  int _framesInWindow = 0;
  Duration _latency = Duration.zero;
  DateTime? _lastFrameAt;

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

  @override
  void initState() {
    super.initState();
    _api = ApiClient(baseUrl: Settings.serverBase);
    _quality = QualityPreset.fromValue(Settings.qualityValue);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    _connect();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _longPress?.cancel();
    _msgSub?.cancel();
    _frameSub?.cancel();
    // 释放被控端可能还按着的修饰键，避免对端「卡键」
    for (final String mod in _heldMods) {
      _signaling?.sendJson(InputEvent.keyUp(mod));
    }
    _heldMods.clear();
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
    await _transport?.dispose();
    _transport = null;
    await _signaling?.close();
    _signaling = null;
    _hello = null;
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
        _toast('被控端错误：${message['err']}');
      default:
        break;
    }
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
        previous.width != hello.width ||
        previous.height != hello.height;

    setState(() {
      _hello = hello;
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
      setState(() => _transport = transport);
      _frameSub = transport.frames.listen(_onFrame);
    } on UnsupportedError {
      // WebRTC 通路未接入 → 回落 JPEG（协议 §5：Agent 未连上 RTC 时仍在推 JPEG）
      await transport.dispose();
      final JpegTransport fallback = JpegTransport();
      await fallback.start(hello: hello, room: room, signaling: signaling);
      if (!mounted) {
        await fallback.dispose();
        return;
      }
      setState(() => _transport = fallback);
      _frameSub = fallback.frames.listen(_onFrame);
      _toast('H.264 通路尚未接入，已回落 JPEG（画面为临时方案）');
    }
    _applyQuality();
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

  void _handleKey(KeyEvent event) {
    if (event is KeyUpEvent) {
      final String? mod = RemoteKeyMapper.modifierName(event.logicalKey);
      if (mod != null && _heldMods.remove(mod)) _send(InputEvent.keyUp(mod));
      return;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;

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
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _topBar(context),
            Expanded(child: _stage()),
          ],
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    final bool wide = MediaQuery.sizeOf(context).width >= 760;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: '返回设备列表',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back, size: 20),
          ),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  widget.device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
                Text(
                  _statusText(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: _statusColor()),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (wide) ...<Widget>[
            _hudChip('$_fps fps'),
            if (_hello != null && _hello!.width > 0)
              _hudChip('${_hello!.width}×${_hello!.height}'),
            if (_latency > Duration.zero) _hudChip('${_latency.inMilliseconds}ms'),
            if (_transport != null) _hudChip(_transport!.kind == 'jpeg' ? 'JPEG 临时' : 'H.264'),
            const SizedBox(width: 6),
          ],
          _qualitySelector(),
          IconButton(
            tooltip: '重新连接',
            onPressed: _reconnect,
            icon: const Icon(Icons.refresh, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _hudChip(String text) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(text, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
    );
  }

  Widget _qualitySelector() {
    return DropdownButtonHideUnderline(
      child: DropdownButton<QualityPreset>(
        value: _selectedPreset(),
        isDense: true,
        dropdownColor: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        style: const TextStyle(fontSize: 12, color: AppColors.text),
        icon: const Icon(Icons.tune, size: 16, color: AppColors.muted),
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
    );
  }

  QualityPreset _selectedPreset() {
    for (final QualityPreset p in AppConfig.qualityPresets) {
      if (p.value == _quality.value) return p;
    }
    return AppConfig.qualityPresets[AppConfig.defaultQualityIndex];
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
    return '实时 · ${hello.name}（${hello.os}）· ${hello.isWebRtc ? 'WebRTC' : 'JPEG 兜底'}';
  }

  Color _statusColor() {
    if (_error != null) return AppColors.danger;
    if (_stalled) return AppColors.warn;
    if (_transport != null) return AppColors.accent;
    return AppColors.muted;
  }

  Widget _stage() {
    if (_connecting) {
      return const MediaPlaceholder(text: '正在加入房间并连接信令…');
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
                if (_stalled) _stalledOverlay(),
                Positioned(left: 12, bottom: 12, child: _inputHint()),
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
      return MediaPlaceholder(
        text: _signaling?.isOpen == true
            ? '信令已连接，等待被控端上线并发送 agent.hello…'
            : '信令未连接，点右上角重试',
      );
    }
    return transport.buildView(fit: BoxFit.contain);
  }

  Widget _stalledOverlay() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.warn.withValues(alpha: 0.6)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.wifi_off, size: 16, color: AppColors.warn),
            SizedBox(width: 8),
            Text('画面中断，等待新帧…', style: TextStyle(color: AppColors.warn, fontSize: 12.5)),
          ],
        ),
      ),
    );
  }

  Widget _inputHint() {
    final bool touch = Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          touch ? '拖动移动光标 · 轻点左键 · 长按右键' : '鼠标/键盘已接管 · 滚轮=滚动 · 右键=右键',
          style: const TextStyle(color: AppColors.muted, fontSize: 11),
        ),
      ),
    );
  }

  Widget _errorView(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.link_off, color: AppColors.danger, size: 40),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, height: 1.6),
            ),
            const SizedBox(height: 18),
            ElevatedButton(onPressed: _reconnect, child: const Text('重新连接')),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('返回设备列表'),
            ),
          ],
        ),
      ),
    );
  }
}