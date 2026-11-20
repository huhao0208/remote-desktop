/// WebRTC 信令载荷的纯函数层（不依赖 `flutter_webrtc`，可直接单测）。
///
/// 字段名严格对齐 `docs/media-protocol.md` §2，改动前先改契约。
library;

/// 服务端 `room_config.ice_servers` → `createPeerConnection({'iceServers': ...})`。
///
/// 兼容两种形态（与 `agent/webrtc_media.py:_parse_ice` 一致）：
///
/// 1. 服务端 `build_ice()` 的结构：
///    ```json
///    {"stun": ["stun:host:3478"],
///     "turn": [{"urls": "turn:host:3478?transport=udp", "username": "...", "credential": "..."}]}
///    ```
/// 2. 扁平数组：`[{"urls": "stun:...", "username": "...", "credential": "..."}]`
///
/// 无法识别的条目直接丢弃（少一个 ICE 服务器不会让协商失败，只会少一条路径）。
List<Map<String, dynamic>> toRtcIceServers(Object? raw) {
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  if (raw is Map) {
    final Object? stun = raw['stun'];
    if (stun is List) {
      for (final Object? url in stun) {
        final Object? urls = _asUrls(url);
        if (urls != null) out.add(<String, dynamic>{'urls': urls});
      }
    }
    final Object? turn = raw['turn'];
    if (turn is List) {
      for (final Object? item in turn) {
        final Map<String, dynamic>? server = _asTurnServer(item);
        if (server != null) out.add(server);
      }
    }
    return out;
  }
  if (raw is List) {
    for (final Object? item in raw) {
      final Map<String, dynamic>? server = _asTurnServer(item);
      if (server != null) out.add(server);
    }
  }
  return out;
}

/// `rtc.offer`（控制端 → Agent，协议 §2.1）。
///
/// `ice` 直接透传服务端下发的原结构（Agent 两种形态都认），省一次请求。
Map<String, dynamic> buildRtcOfferMessage({
  required String sdp,
  required Object? ice,
  required String peer,
}) {
  return <String, dynamic>{
    'p': 'rtc.offer',
    'sdp': sdp,
    'ice': ice ?? const <String, Object?>{},
    'peer': peer,
  };
}

/// `rtc.ice`（双向，协议 §2.3）。
Map<String, dynamic> buildRtcIceMessage({
  required String candidate,
  required String? sdpMid,
  required int? sdpMLineIndex,
  required String peer,
}) {
  return <String, dynamic>{
    'p': 'rtc.ice',
    'candidate': candidate,
    'sdpMid': sdpMid,
    'sdpMLineIndex': sdpMLineIndex,
    'peer': peer,
  };
}

/// 收到的 `rtc.ice` 载荷。
class RtcIcePayload {
  const RtcIcePayload({required this.candidate, this.sdpMid, this.sdpMLineIndex});

  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  static RtcIcePayload? fromJson(Map<String, dynamic> json) {
    final Object? candidate = json['candidate'];
    if (candidate is! String || candidate.trim().isEmpty) return null;
    final Object? mid = json['sdpMid'];
    final Object? index = json['sdpMLineIndex'];
    return RtcIcePayload(
      candidate: candidate,
      sdpMid: mid is String ? mid : null,
      sdpMLineIndex: index is num ? index.toInt() : int.tryParse('$index'),
    );
  }
}

Object? _asUrls(Object? value) {
  if (value is String) {
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (value is List) {
    final List<String> urls = value
        .whereType<String>()
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList();
    return urls.isEmpty ? null : urls;
  }
  return null;
}

Map<String, dynamic>? _asTurnServer(Object? raw) {
  if (raw is! Map) return null;
  final Object? urls = _asUrls(raw['urls']);
  if (urls == null) return null;
  final Map<String, dynamic> server = <String, dynamic>{'urls': urls};
  final Object? username = raw['username'];
  final Object? credential = raw['credential'];
  if (username is String && username.isNotEmpty) server['username'] = username;
  if (credential is String && credential.isNotEmpty) server['credential'] = credential;
  return server;
}