import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/models.dart';
import '../core/settings.dart';
import '../signaling/signaling_client.dart';
import 'media_transport.dart';
import 'rtc_signaling.dart';

/// 连接不可用时的回调（页面据此回落 JPEG，协议 §5）。
typedef WebRtcFallback = void Function(String reason);

/// WebRTC（H.264 / SRTP over UDP）接收通路。
///
/// 职责边界：只负责「协商 + 收流 + 出画面 + 出统计」，输入事件仍由远控页经信令
/// 发（协议 §6 的 `input` 语义一行不改）。协商流程见 `docs/media-protocol.md` §2：
///
/// ```
/// 本端                                          Agent
///  rtc.offer {sdp, ice, peer}  ───────────────►  建 PC / 挂 ScreenTrack
///  ◄─────────────── rtc.answer {sdp, bitrate}    createAnswer + setLocal
///  rtc.ice  ◄──────────────────────────────────►  rtc.ice（双向 trickle）
///  ══════════ SRTP/UDP 媒体（不经服务端）══════════
/// ```
///
/// 清晰度（协议 §3 的命门）：接收端必须以 **maintain-resolution** 协商，宁可掉帧
/// 也不让编码器降分辨率；真正的降级开关在被控端（8 Mbps + 同样策略），本端能做
/// 的是：① 只声明 recvonly，不做任何缩放；② 把 `degradationPreference` 写进
/// RTP 参数；③ 画面按 1:1 像素渲染（`BoxFit.contain`，不超采样）。
///
/// v2 能力（音频 / 剪贴板 / 多屏 / 修饰键）只留挂点，见文件末尾 TODO。
class WebRtcTransport implements MediaTransport {
  final StreamController<FramePacket> _frames = StreamController<FramePacket>.broadcast();
  final ValueNotifier<TransportStats> _stats =
      ValueNotifier<TransportStats>(const TransportStats());

  RTCPeerConnection? _pc;
  RTCVideoRenderer? _renderer;
  SignalingClient? _signaling;
  StreamSubscription<Map<String, dynamic>>? _signalSub;
  Timer? _statsTimer;

  /// 候选可能早于 answer 到达，先缓存再补投（协议 §2.3）。
  final List<RTCIceCandidate> _pendingCandidates = <RTCIceCandidate>[];

  bool _remoteDescriptionSet = false;
  bool _disposed = false;
  bool _fallbackNotified = false;

  int _lastFrames = 0;
  DateTime? _lastStatsAt;

  String _peer = 'ctl';

  /// 连接 failed/disconnected 时触发；页面负责切回 [JpegTransport]。
  WebRtcFallback? onFallback;

  /// 已经判定不可用的原因（可能在页面挂上 [onFallback] 之前就发生，页面据此补查）。
  String? get fallbackReason => _fallbackReason;
  String? _fallbackReason;

  @override
  String get kind => 'webrtc';

  @override
  String get label => 'H.264 / WebRTC';

  @override
  Stream<FramePacket> get frames => _frames.stream;

  @override
  ValueListenable<TransportStats> get stats => _stats;

  /// 供页面判断「原生纹理里是否已经有画面」（HUD 之外的自检用）。
  RTCVideoRenderer? get renderer => _renderer;

  @override
  Future<void> start({
    required AgentHello hello,
    required RoomConfig room,
    required SignalingClient signaling,
  }) async {
    _peer = Settings.deviceId.isEmpty ? 'ctl' : Settings.deviceId;
    _signaling = signaling;
    _signalSub = signaling.messages.listen(_onSignal);

    final RTCVideoRenderer renderer = RTCVideoRenderer();
    await renderer.initialize();
    _renderer = renderer;

    final RTCPeerConnection pc = await createPeerConnection(<String, dynamic>{
      // 服务端由 build_ice() 下发，转成 flutter_webrtc 认识的数组形态
      'iceServers': toRtcIceServers(room.iceServers),
      'bundlePolicy': 'max-bundle',
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;

    // 只收不发：不申请摄像头/麦克风，也就没有权限弹窗
    final RTCRtpTransceiver transceiver = await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    await _preferMaintainResolution(transceiver);

    pc.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'audio') {
        // TODO(v2-audio): 协议 v2 §1 —— 挂到页面隐藏的音频元素/播放器，静音只改
        // 本地音量，不通知 Agent。v1 不实现，收到 audio 轨直接忽略。
        return;
      }
      final List<MediaStream> streams = event.streams;
      if (streams.isEmpty) {
        debugPrint('[webrtc] onTrack 未带 stream，无法渲染');
        return;
      }
      renderer.srcObject = streams.first;
    };
    pc.onIceCandidate = (RTCIceCandidate candidate) {
      final String? value = candidate.candidate;
      if (value == null || value.isEmpty) return;
      _send(buildRtcIceMessage(
        candidate: value,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
        peer: _peer,
      ));
    };
    pc.onConnectionState = (RTCPeerConnectionState state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _notifyFallback(state == RTCPeerConnectionState.RTCPeerConnectionStateFailed
            ? '连接失败'
            : '连接断开');
      }
    };
    // TODO(v2-multiscreen): 协议 v2 §3 —— 切换显示器时 Agent 会重建视频轨并主动
    // 重协商（发来一条 rtc.offer）。届时需要在 _onSignal 里 createAnswer +
    // setLocalDescription，并把 answer 回给 Agent。v1 不处理入向 offer。

    final RTCSessionDescription offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _send(buildRtcOfferMessage(
      sdp: offer.sdp ?? '',
      ice: room.iceServers,
      peer: _peer,
    ));

    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollStats());
  }

  // ------------------------------------------------------------ 信令

  void _onSignal(Map<String, dynamic> message) {
    if (_disposed) return;
    switch (message['p']) {
      case 'rtc.answer':
        _onAnswer(message);
      case 'rtc.ice':
        _onRemoteCandidate(message);
      case 'rtc.close':
        // 对端主动收线（离开房间/降级）：按断开处理，页面回落 JPEG
        _notifyFallback('对端关闭了 H.264 通路');
      default:
        break;
    }
  }

  Future<void> _onAnswer(Map<String, dynamic> message) async {
    final RTCPeerConnection? pc = _pc;
    final Object? sdp = message['sdp'];
    if (pc == null || sdp is! String || sdp.isEmpty) return;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      _remoteDescriptionSet = true;
      final List<RTCIceCandidate> pending = List<RTCIceCandidate>.of(_pendingCandidates);
      _pendingCandidates.clear();
      for (final RTCIceCandidate candidate in pending) {
        await pc.addCandidate(candidate);
      }
    } catch (e) {
      debugPrint('[webrtc] setRemoteDescription 失败：$e');
      _notifyFallback('SDP 协商失败');
    }
  }

  Future<void> _onRemoteCandidate(Map<String, dynamic> message) async {
    final RTCPeerConnection? pc = _pc;
    final RtcIcePayload? payload = RtcIcePayload.fromJson(message);
    if (pc == null || payload == null) return;
    final RTCIceCandidate candidate = RTCIceCandidate(
      payload.candidate,
      payload.sdpMid,
      payload.sdpMLineIndex,
    );
    if (!_remoteDescriptionSet) {
      _pendingCandidates.add(candidate);
      return;
    }
    try {
      await pc.addCandidate(candidate);
    } catch (e) {
      // 候选冲突/过期很常见，忽略即可，媒体链路会自己收敛
      debugPrint('[webrtc] addCandidate 忽略：$e');
    }
  }

  void _send(Map<String, dynamic> message) {
    _signaling?.sendJson(message);
  }

  // ------------------------------------------------------------ 清晰度

  /// 等价于浏览器里的 `transceiver.degradationPreference = 'maintain-resolution'`。
  ///
  /// flutter_webrtc 没有 transceiver 级属性，只能改 sender 的 RTP 参数；recvonly
  /// 的 sender 没有 SSRC，部分平台会拒绝，属预期，**不影响收流**。真正的保证在
  /// 被控端（协议 §3：8 Mbps + 同样策略），这里做的是「本端不主动要求降级」。
  Future<void> _preferMaintainResolution(RTCRtpTransceiver transceiver) async {
    try {
      final RTCRtpParameters parameters = transceiver.sender.parameters;
      parameters.degradationPreference = RTCDegradationPreference.MAINTAIN_RESOLUTION;
      final bool ok = await transceiver.sender.setParameters(parameters);
      if (!ok) {
        debugPrint('[webrtc] degradationPreference 被平台拒绝（recvonly 无 SSRC），忽略');
      }
    } catch (e) {
      debugPrint('[webrtc] degradationPreference 设置失败（忽略）：$e');
    }
  }

  // ------------------------------------------------------------ 统计

  Future<void> _pollStats() async {
    final RTCPeerConnection? pc = _pc;
    if (pc == null || _disposed) return;
    List<StatsReport> reports;
    try {
      reports = await pc.getStats();
    } catch (_) {
      return;
    }
    for (final StatsReport report in reports) {
      if (report.type != 'inbound-rtp') continue;
      final Map<dynamic, dynamic> values = report.values;
      final String kind = (values['kind'] ?? values['mediaType'] ?? '').toString();
      if (kind != 'video') continue;
      _updateStats(values);
      return;
    }
  }

  /// 字段名各平台略有差异（`framesPerSecond` vs 自算 `framesDecoded` 差值），两种都试。
  void _updateStats(Map<dynamic, dynamic> values) {
    final int width = _asInt(values['frameWidth']);
    final int height = _asInt(values['frameHeight']);
    final int frames = _asInt(values['framesDecoded'] ?? values['framesReceived']);

    int fps = _asInt(values['framesPerSecond']);
    final DateTime now = DateTime.now();
    final DateTime? last = _lastStatsAt;
    if (fps <= 0 && last != null && frames > 0) {
      final double seconds = now.difference(last).inMilliseconds / 1000.0;
      if (seconds > 0.1) fps = ((frames - _lastFrames) / seconds).round();
    }
    if (frames > 0) {
      _lastFrames = frames;
      _lastStatsAt = now;
    }
    if (fps < 0) fps = 0;

    _stats.value = TransportStats(fps: fps, width: width, height: height);
  }

  static int _asInt(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  // ------------------------------------------------------------ 降级

  void _notifyFallback(String reason) {
    if (_disposed || _fallbackNotified) return;
    _fallbackNotified = true;
    _fallbackReason = reason;
    onFallback?.call(reason);
  }

  // ------------------------------------------------------------ 视图

  @override
  Widget buildView({required BoxFit fit}) {
    final RTCVideoRenderer? renderer = _renderer;
    if (renderer == null) {
      return const MediaPlaceholder(text: 'H.264 通路初始化中…');
    }
    return RTCVideoView(
      renderer,
      objectFit: fit == BoxFit.cover
          ? RTCVideoViewObjectFit.RTCVideoViewObjectFitCover
          : RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      filterQuality: FilterQuality.low,
      placeholderBuilder: (BuildContext context) =>
          const MediaPlaceholder(text: '已协商 H.264，等待被控端首帧…'),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _statsTimer?.cancel();
    _statsTimer = null;
    final SignalingClient? signaling = _signaling;
    if (signaling != null && signaling.isOpen) {
      // 可选消息（协议 §2.4）：让 Agent 立刻恢复 JPEG 兜底推流
      signaling.sendJson(<String, dynamic>{'p': 'rtc.close'});
    }
    await _signalSub?.cancel();
    _signalSub = null;
    _pendingCandidates.clear();
    _stats.value = const TransportStats();
    _stats.dispose();

    final RTCVideoRenderer? renderer = _renderer;
    _renderer = null;
    if (renderer != null) {
      renderer.srcObject = null;
      await renderer.dispose();
    }
    final RTCPeerConnection? pc = _pc;
    _pc = null;
    if (pc != null) {
      try {
        await pc.close();
      } catch (_) {
        // 已断开
      }
      await pc.dispose();
    }
    if (!_frames.isClosed) await _frames.close();
  }
}

// ---------------------------------------------------------------------------
// v2 能力挂点（协议 v2，FROZEN；v1 只留接口，不实现）
//
// | 能力     | 控制端要做的事                                              |
// |----------|-------------------------------------------------------------|
// | 音频     | onTrack 里 kind=='audio' → 播放器；本地静音，不发消息      |
// | 剪贴板   | {p:'clip',dir:'up'|'down',text} + {p:'clip.sync'}，md5 去重 |
// | 多屏     | {p:'screens'} / {p:'screen.select'}，Agent 重协商时答 offer |
// | 修饰键   | 已在远控页实现 v1 版 keydown/keyup；v2 要求 blur 时全释放  |
//
// 以上消息都复用现有 WS，服务端零改动。
// ---------------------------------------------------------------------------