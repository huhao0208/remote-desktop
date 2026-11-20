/// 服务端契约模型（字段名严格对齐 `srv2/server.py` 与 `docs/media-protocol.md`）。
library;

bool _asBool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == '1' || v.toLowerCase() == 'true';
  return false;
}

int _asInt(Object? v, [int fallback = 0]) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

String _asString(Object? v, [String fallback = '']) => v?.toString() ?? fallback;

/// `/api/v1/login/by_mobile` 的返回。
class LoginResult {
  const LoginResult({
    required this.token,
    required this.uid,
    required this.mobile,
    required this.nickname,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
  });

  final String token;
  final String uid;
  final String mobile;
  final String nickname;
  final String deviceId;
  final String deviceName;
  final String platform;

  factory LoginResult.fromJson(Map<String, dynamic> json) {
    final dev = json['device'];
    final device = dev is Map ? dev.cast<String, dynamic>() : const <String, dynamic>{};
    return LoginResult(
      token: _asString(json['token']),
      uid: _asString(json['uid']),
      mobile: _asString(json['mobile']),
      nickname: _asString(json['nickname']),
      deviceId: _asString(device['device_id']),
      deviceName: _asString(device['device_name']),
      platform: _asString(device['platform']),
    );
  }
}

/// `/api/v1/device/list` 列表项。
class DeviceInfo {
  const DeviceInfo({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.online,
    required this.isSelf,
    required this.controllable,
    required this.lastSeen,
  });

  final String deviceId;
  final String name;
  final String platform;
  final bool online;
  final bool isSelf;
  final bool controllable;
  final int lastSeen;

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
        deviceId: _asString(json['device_id']),
        name: _asString(json['device_name'], _asString(json['platform'], '未命名设备')),
        platform: _asString(json['platform'], 'unknown'),
        online: _asBool(json['online']),
        isSelf: _asBool(json['is_self']),
        controllable: _asBool(json['controllable']),
        lastSeen: _asInt(json['last_seen']),
      );

  String get platformLabel {
    switch (platform) {
      case 'pc':
        return '电脑';
      case 'mac':
      case 'darwin':
        return 'macOS';
      case 'windows':
        return 'Windows';
      case 'linux':
        return 'Linux';
      case 'android':
        return 'Android';
      case 'android_tv':
        return 'Android TV';
      case 'ios':
        return 'iOS';
      case 'mobile':
        return '手机';
      default:
        return platform.isEmpty ? '未知' : platform;
    }
  }
}

/// `/api/v1/room/join/by_device/{device_id}` 返回的 RoomConfig。
class RoomConfig {
  const RoomConfig({
    required this.signalingServer,
    required this.roomToken,
    required this.roomId,
    required this.iceServers,
  });

  /// 服务端下发的信令地址，形如 `wss://host:8444/ws/signaling`。
  final String signalingServer;

  /// 房间 token（**不是** 登录 token）。
  final String roomToken;
  final String roomId;

  /// 服务端下发的 ICE 配置，**原样保存**：
  /// `{"stun": [...], "turn": [{urls, username, credential}]}`（协议 §2.1）。
  ///
  /// 既用于 `rtc.offer.ice` 透传，也由 `toRtcIceServers()` 转成
  /// `createPeerConnection` 需要的数组形态。老服务端也可能给扁平数组，都兼容。
  final Object? iceServers;

  factory RoomConfig.fromJson(Map<String, dynamic> json) {
    return RoomConfig(
      signalingServer: _asString(json['signaling_server']),
      roomToken: _asString(json['token']),
      roomId: _asString(json['room_id']),
      iceServers: json['ice_servers'],
    );
  }

  /// 组装信令 WS 地址：`wss://<host>/ws/signaling?token=<roomToken>&device_id=<self>`
  ///
  /// 服务端下发的地址可能还是默认域名（`UU_PUBLIC_BASE` 没配），此时退回用
  /// 用户实际访问的 API base 推导，避免连到错误的主机。
  String signalingUrl({required String deviceId, required String apiBase}) {
    final fallback = _resolveWsBase(apiBase);
    var wsBase = fallback;
    var path = '/ws/signaling';
    final server = signalingServer.trim();
    if (server.isNotEmpty) {
      final uri = Uri.tryParse(server);
      final api = Uri.tryParse(fallback);
      final sameHost = uri != null && api != null && uri.host.isNotEmpty && uri.host == api.host;
      if (sameHost) {
        wsBase = '${uri.scheme}://${uri.authority}';
        if (uri.path.isNotEmpty && uri.path != '/') path = uri.path;
      }
    }
    final query = <String, String>{
      'token': roomToken,
      if (deviceId.isNotEmpty) 'device_id': deviceId,
    };
    return Uri.parse(wsBase).replace(path: path, queryParameters: query).toString();
  }

  static String _resolveWsBase(String apiBase) {
    var base = apiBase.trim();
    if (base.startsWith('https://')) {
      base = 'wss://${base.substring(8)}';
    } else if (base.startsWith('http://')) {
      base = 'ws://${base.substring(7)}';
    } else if (!base.startsWith('ws://') && !base.startsWith('wss://')) {
      base = 'wss://$base';
    }
    return base.replaceFirst(RegExp(r'/+$'), '');
  }
}

/// `agent.hello`（见 docs/media-protocol.md §1）。
class AgentHello {
  const AgentHello({
    required this.name,
    required this.os,
    required this.width,
    required this.height,
    required this.media,
    required this.fps,
  });

  final String name;
  final String os;
  final int width;
  final int height;

  /// `webrtc` | `jpeg`；老 Agent 不发该字段时按 `jpeg` 处理（向后兼容）。
  final String media;
  final int fps;

  bool get isWebRtc => media.toLowerCase() == 'webrtc';

  factory AgentHello.fromJson(Map<String, dynamic> json) {
    final screen = json['screen'];
    final s = screen is Map ? screen.cast<String, dynamic>() : const <String, dynamic>{};
    final stream = json['stream'];
    final st = stream is Map ? stream.cast<String, dynamic>() : const <String, dynamic>{};
    final media = _asString(json['media']).toLowerCase();
    return AgentHello(
      name: _asString(json['name'], '被控端'),
      os: _asString(json['os'], 'unknown'),
      width: _asInt(s['w']),
      height: _asInt(s['h']),
      media: media.isEmpty ? 'jpeg' : media,
      fps: _asInt(st['fps'], 30),
    );
  }
}