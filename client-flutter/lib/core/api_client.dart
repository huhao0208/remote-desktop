import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'device_identity.dart';
import 'models.dart';

/// 服务端业务错误（HTTP 层正常但 `code != 0`，或网络层失败）。
class ApiException implements Exception {
  ApiException(this.code, this.message);

  final int code;
  final String message;

  bool get isAuthError => code == 1001;

  @override
  String toString() => message;
}

/// 极简 REST 客户端：`{code,msg,data}` 信封 + `Authorization: Bearer <token>`。
///
/// 直接用 `dart:io HttpClient`（而不是 package:http），因为自托管服务端
/// 常用自签证书，需要 `badCertificateCallback`；同一个 client 也复用于 WS。
class ApiClient {
  ApiClient({required String baseUrl})
      : baseUrl = baseUrl.trim().replaceFirst(RegExp(r'/+$'), ''),
        _http = _newHttpClient();

  final String baseUrl;
  final HttpClient _http;

  static HttpClient _newHttpClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    // 自托管部署多为自签证书，v1 骨架先全放行；正式版应改为证书固定/系统信任链。
    ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic> body = const <String, dynamic>{},
    String? token,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    try {
      final request = await _http.postUrl(uri).timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final payload = utf8.encode(jsonEncode(body));
      request.headers.contentLength = payload.length;
      request.add(payload);

      final response = await request.close().timeout(timeout);
      final text = await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode >= 400) {
        throw ApiException(response.statusCode, 'HTTP ${response.statusCode}：服务端异常');
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map) throw ApiException(-1, '服务端返回格式异常（不是 JSON 对象）');
      final map = decoded.cast<String, dynamic>();
      final code = (map['code'] as num?)?.toInt() ?? -1;
      if (code != 0) {
        final msg = (map['msg'] as String?)?.trim() ?? '';
        throw ApiException(code, msg.isEmpty ? '请求失败（code=$code）' : msg);
      }
      final data = map['data'];
      return data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException(-2, '请求超时，请检查服务端地址与网络');
    } on HandshakeException catch (e) {
      throw ApiException(-3, 'TLS 握手失败：${e.message}');
    } on SocketException catch (e) {
      throw ApiException(-4, '无法连接服务端：${e.message}');
    } on FormatException {
      throw ApiException(-5, '服务端返回的不是合法 JSON');
    }
  }

  /// 手机号登录，并在登录请求里顺带注册「本机」设备。
  Future<LoginResult> loginByMobile(String mobile) async {
    final data = await post('/api/v1/login/by_mobile', body: <String, dynamic>{
      'mobile': mobile.trim(),
      'register_device': 1,
      'uuid': DeviceIdentity.uuid,
      'device_name': DeviceIdentity.name,
      'platform': DeviceIdentity.platform,
    });
    final result = LoginResult.fromJson(data);
    if (result.token.isEmpty) throw ApiException(-1, '服务端未返回 token');
    if (result.deviceId.isEmpty) throw ApiException(-1, '服务端未返回 device_id');
    return result;
  }

  Future<List<DeviceInfo>> listDevices({
    required String token,
    required String selfDeviceId,
  }) async {
    final data = await post(
      '/api/v1/device/list',
      body: <String, dynamic>{'device_id': selfDeviceId},
      token: token,
    );
    final raw = data['list'] ?? data['devices'];
    if (raw is! List) return const <DeviceInfo>[];
    return raw
        .whereType<Map>()
        .map((e) => DeviceInfo.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  /// 与 Agent 进同一个房间（服务端复用该设备最近一个未关闭房间）。
  Future<RoomConfig> joinRoom({required String token, required String deviceId}) async {
    final data = await post(
      '/api/v1/room/join/by_device/${Uri.encodeComponent(deviceId)}',
      token: token,
    );
    final room = RoomConfig.fromJson(data);
    if (room.roomToken.isEmpty) throw ApiException(-1, '服务端未返回房间 token');
    return room;
  }

  Future<Map<String, dynamic>> userInfo(String token) => post('/api/v1/user/info', token: token);

  /// 连通性自检：`GET /healthz`。
  Future<bool> ping({Duration timeout = const Duration(seconds: 6)}) async {
    try {
      final request = await _http.getUrl(Uri.parse('$baseUrl/healthz')).timeout(timeout);
      final response = await request.close().timeout(timeout);
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void close() => _http.close(force: true);
}