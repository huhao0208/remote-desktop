import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../core/models.dart';
import '../signaling/signaling_client.dart';
import 'media_transport.dart';

/// JPEG 兜底通路：服务端 WS 透传二进制帧。
///
/// 帧格式（协议 §6，不变）：`"FRM1"` + 8 字节大端毫秒时间戳 + JPEG 数据。
/// 老 Agent 也可能只发 `"FRM1"` + JPEG（无时间戳），这里兼容两种。
///
/// ⚠️ 兜底方案：`Image.memory` 每帧都会走一次解码+上传纹理，1080p@30 时 CPU/GPU
/// 开销很大，且会有 1 帧闪烁。`agent.hello.media == "webrtc"` 时走
/// [WebRtcTransport]（原生纹理），只有 WebRTC 不可用/断链才回落到这里。
class JpegTransport extends MediaTransport {
  final ValueNotifier<Uint8List?> _latest = ValueNotifier<Uint8List?>(null);
  final StreamController<FramePacket> _frames = StreamController<FramePacket>.broadcast();

  StreamSubscription<Uint8List>? _sub;

  static const List<int> _magic = <int>[0x46, 0x52, 0x4D, 0x31]; // "FRM1"

  @override
  String get kind => 'jpeg';

  @override
  String get label => 'JPEG over WS（临时）';

  @override
  Stream<FramePacket> get frames => _frames.stream;

  @override
  Future<void> start({
    required AgentHello hello,
    required RoomConfig room,
    required SignalingClient signaling,
  }) async {
    _sub ??= signaling.binary.listen(_onBinary);
  }

  void _onBinary(Uint8List data) {
    if (data.length < 6) return;
    for (var i = 0; i < _magic.length; i++) {
      if (data[i] != _magic[i]) return;
    }
    var offset = 4;
    var latency = Duration.zero;
    // 紧随 FRM1 的不是 SOI(FFD8)，说明带了 8 字节时间戳
    final hasTimestamp = !(data[4] == 0xFF && data[5] == 0xD8) && data.length > 12;
    if (hasTimestamp) {
      final ts = ByteData.sublistView(data, 4, 12).getUint64(0, Endian.big);
      final now = DateTime.now().millisecondsSinceEpoch;
      if (ts > 0 && ts <= now) latency = Duration(milliseconds: now - ts);
      offset = 12;
    }
    if (data.length <= offset) return;
    final jpeg = Uint8List.sublistView(data, offset);
    _latest.value = jpeg;
    if (!_frames.isClosed) _frames.add(FramePacket(bytes: jpeg, latency: latency));
  }

  @override
  Widget buildView({required BoxFit fit}) {
    return ValueListenableBuilder<Uint8List?>(
      valueListenable: _latest,
      builder: (BuildContext context, Uint8List? frame, Widget? child) {
        if (frame == null) {
          return const MediaPlaceholder(text: '已连接信令，等待被控端画面…');
        }
        // 每帧重编码的成本只在这个兜底分支里；WebRTC 通路走 RTCVideoView
        return Image.memory(
          frame,
          fit: fit,
          gaplessPlayback: true,
          filterQuality: FilterQuality.low,
        );
      },
    );
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _latest.dispose();
    await _frames.close();
  }
}