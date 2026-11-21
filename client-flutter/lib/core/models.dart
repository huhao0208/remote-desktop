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

List<String> _asStringList(Object? v) {
  if (v is! List) return const <String>[];
  return <String>[
    for (final Object? e in v)
      if (e != null && e.toString().isNotEmpty) e.toString(),
  ];
}

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

/// `agent.hello`（见 docs/media-protocol.md §1 / v2 §1）。
class AgentHello {
  const AgentHello({
    required this.name,
    required this.os,
    required this.width,
    required this.height,
    required this.media,
    required this.fps,
    this.audio = false,
    this.screens = 1,
    this.version,
    this.ip,
    this.capture,
    this.maxFps = 60,
    this.autoLock = false,
    this.power = const <String>[],
    this.privacy = 'off',
    this.privacyEngine = 'unknown',
    this.file = false,
    this.receiveDir,
    this.cursorEngine = 'unknown',
    this.mic = false,
  });

  final String name;
  final String os;
  final int width;
  final int height;

  /// `webrtc` | `jpeg`；老 Agent 不发该字段时按 `jpeg` 处理（向后兼容）。
  final String media;
  final int fps;

  /// 协议 v2 §1：本会话是否会有音频轨。老 Agent 不发 → false。
  final bool audio;

  /// 协议 v2 §3：显示器数量（连接信息面板 / 切屏按钮用）。老 Agent → 1。
  final int screens;

  /// 被控端 Agent 版本（v0.2.0 起 `--version` 与 hello 同源）。老 Agent → null。
  final String? version;

  /// 被控端局域网 IP（用于排障对表）。老 Agent → null。
  final String? ip;

  /// 采集后端自述（`mss` / `screencapture` / `dxgi` …）。老 Agent → null。
  final String? capture;

  /// 被控端粗测的采集上限（fps）。只用来在画质面板里提示「超出采集能力」，
  /// **不做硬拦截**——探测本身有误差，误禁比误开更烦人。老 Agent → 60。
  final int maxFps;

  /// 结束远程自动锁屏（官方 `autoLock`）。老 Agent → false。
  final bool autoLock;

  /// 支持的电源动作（`lock` / `reboot` / `shutdown` / `taskmgr`）。
  /// 空列表 = 老 Agent，按「全部支持」处理更宽松？不——按全部支持处理会让用户
  /// 点了没反应，所以老 Agent 一律只放行 `shutdown`（它一定有）。
  final List<String> power;

  /// 当前防窥档位 key。老 Agent → `off`。
  final String privacy;

  /// 防窥引擎：`overlay`（真遮罩窗）/ `unsupported`（平台做不了）。
  final String privacyEngine;

  /// 协议 v3 §2：是否支持文件传输。老 Agent → false（菜单里置灰并说明要升级）。
  final bool file;

  /// 被控端的文件接收目录（显示用：「发送到 …」）。
  final String? receiveDir;

  /// 协议 v3 §3：`win-show-cursor` / `mac-cgdisplay` / `unsupported`。
  /// `unsupported` 时控制端要把「使用主控端鼠标」置灰，而不是给个点了没反应的开关。
  final String cursorEngine;

  /// 被控端能不能隐藏自己的系统光标（决定「使用主控端鼠标」可不可选）。
  bool get cursorSupported => cursorEngine != 'unsupported' && cursorEngine != 'unknown';

  /// 协议 v3 §6：被控端能否接收控制端麦克风（有可用放音设备）。
  /// 老 Agent 不发该字段 → false，控制端把麦克风按钮置灰并说明要升级。
  final bool mic;

  bool supportsPower(String action) {
    if (power.isEmpty) return action == 'shutdown';
    return power.contains(action);
  }

  bool get isWebRtc => media.toLowerCase() == 'webrtc';

  factory AgentHello.fromJson(Map<String, dynamic> json) {
    final screen = json['screen'];
    final s = screen is Map ? screen.cast<String, dynamic>() : const <String, dynamic>{};
    final stream = json['stream'];
    final st = stream is Map ? stream.cast<String, dynamic>() : const <String, dynamic>{};
    final media = _asString(json['media']).toLowerCase();
    final String version = _asString(json['version']);
    final String ip = _asString(json['ip']);
    final String capture = _asString(json['capture']);
    return AgentHello(
      name: _asString(json['name'], '被控端'),
      os: _asString(json['os'], 'unknown'),
      width: _asInt(s['w']),
      height: _asInt(s['h']),
      media: media.isEmpty ? 'jpeg' : media,
      fps: _asInt(st['fps'], 30),
      audio: _asBool(json['audio']),
      screens: _asInt(json['screens'], 1).clamp(1, 16),
      version: version.isEmpty ? null : version,
      ip: ip.isEmpty ? null : ip,
      capture: capture.isEmpty ? null : capture,
      maxFps: _asInt(json['max_fps'], 60).clamp(1, 144),
      autoLock: _asBool(json['auto_lock']),
      power: _asStringList(json['power']),
      privacy: _asString(json['privacy'], 'off'),
      privacyEngine: _asString(json['privacy_engine'], 'unknown'),
      file: _asBool(json['file']),
      receiveDir: _asString(json['receive_dir']).isEmpty ? null : _asString(json['receive_dir']),
      cursorEngine: _asString(json['cursor'], 'unknown'),
      mic: _asBool(json['mic']),
    );
  }
}
/// 一块被控端显示器（协议 v2 §3 的 `screens.list[]` 元素）。
///
/// `id` 就是 Agent 侧显示器下标，`screen.select` 直接回传它；**不要用列表下标
/// 代替 id**——多屏热插拔后两者可能不一致。
class ScreenInfo {
  const ScreenInfo({
    required this.id,
    required this.width,
    required this.height,
    this.x = 0,
    this.y = 0,
    this.name = '',
    this.primary = false,
  });

  final int id;
  final int width;
  final int height;
  final int x;
  final int y;
  final String name;
  final bool primary;

  /// 界面上的一行文案：`内建 · 2048×1280`（主屏加「主」标）。
  String get label {
    final String n = name.isEmpty ? '显示屏 ${id + 1}' : name;
    final String res = '$width×$height';
    return primary ? '$n · $res（主）' : '$n · $res';
  }

  factory ScreenInfo.fromJson(Map<String, dynamic> json) => ScreenInfo(
        id: _asInt(json['id']),
        width: _asInt(json['w']),
        height: _asInt(json['h']),
        x: _asInt(json['x']),
        y: _asInt(json['y']),
        name: _asString(json['name']),
        primary: _asBool(json['primary']),
      );

  static List<ScreenInfo> listFrom(Object? raw) {
    if (raw is! List) return const <ScreenInfo>[];
    final List<ScreenInfo> out = <ScreenInfo>[];
    for (final Object? item in raw) {
      if (item is Map) out.add(ScreenInfo.fromJson(item.cast<String, dynamic>()));
    }
    return out;
  }
}
