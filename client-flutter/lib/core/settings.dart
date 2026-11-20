import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';

/// 本地持久化：服务端地址、登录 token、本机稳定指纹。
///
/// 用 [SharedPreferences]（macOS: NSUserDefaults / Android: SharedPreferences /
/// Windows+Linux: 文件），保证同一台机器 `uuid` 稳定，服务端据此去重设备。
class Settings {
  Settings._();

  static const String _kServer = 'server_base';
  static const String _kToken = 'auth_token';
  static const String _kUid = 'auth_uid';
  static const String _kMobile = 'auth_mobile';
  static const String _kNickname = 'auth_nickname';
  static const String _kUuid = 'device_uuid';
  static const String _kDeviceId = 'device_id';
  static const String _kQuality = 'quality_preset';

  static late SharedPreferences _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    if ((_prefs.getString(_kUuid) ?? '').isEmpty) {
      await _prefs.setString(_kUuid, _newUuid());
    }
  }

  /// 稳定设备指纹（首次启动生成并落盘）。
  static String get deviceUuid => _prefs.getString(_kUuid) ?? '';

  static String get serverBase {
    final v = (_prefs.getString(_kServer) ?? '').trim();
    if (v.isEmpty) return AppConfig.defaultServer;
    return v.replaceFirst(RegExp(r'/+$'), '');
  }

  static Future<void> setServerBase(String value) async {
    var v = value.trim().replaceFirst(RegExp(r'/+$'), '');
    if (v.isNotEmpty && !v.startsWith('http://') && !v.startsWith('https://')) {
      v = 'https://$v';
    }
    if (v == AppConfig.defaultServer) {
      await _prefs.remove(_kServer);
    } else {
      await _prefs.setString(_kServer, v);
    }
  }

  static String get token => _prefs.getString(_kToken) ?? '';
  static String get uid => _prefs.getString(_kUid) ?? '';
  static String get mobile => _prefs.getString(_kMobile) ?? '';
  static String get nickname => _prefs.getString(_kNickname) ?? '';

  /// 服务端登记的「本机」device_id（登录时 register_device 返回）。
  static String get deviceId => _prefs.getString(_kDeviceId) ?? '';

  static Future<void> saveSession({
    required String token,
    required String uid,
    required String mobile,
    required String nickname,
    required String deviceId,
  }) async {
    await _prefs.setString(_kToken, token);
    await _prefs.setString(_kUid, uid);
    await _prefs.setString(_kMobile, mobile);
    await _prefs.setString(_kNickname, nickname);
    await _prefs.setString(_kDeviceId, deviceId);
  }

  /// 只清登录态，保留 device_uuid（同机重登仍然是同一台设备）。
  static Future<void> clearSession() async {
    await _prefs.remove(_kToken);
    await _prefs.remove(_kUid);
    await _prefs.remove(_kMobile);
    await _prefs.remove(_kNickname);
    await _prefs.remove(_kDeviceId);
  }

  static String get qualityValue => _prefs.getString(_kQuality) ?? '';
  static Future<void> setQualityValue(String value) => _prefs.setString(_kQuality, value);

  static bool get hasSession => token.isNotEmpty && deviceId.isNotEmpty;

  static String _newUuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant RFC 4122
    final h = b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }
}