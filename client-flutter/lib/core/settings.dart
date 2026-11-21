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
  static const String _kStreamFps = 'stream_fps';
  static const String _kStreamRes = 'stream_resolution';
  static const String _kStreamResWidth = 'stream_resolution_width';
  static const String _kStreamBitrate = 'stream_bitrate';
  static const String _kAllowBeControlled = 'allow_be_controlled';
  static const String _kClipboardSync = 'clipboard_sync';
  static const String _kShortcuts = 'shortcuts_json';
  static const String _kMiniWindow = 'mini_window_json';

  // ---- 自动升级（v0.2.0 起）----
  static const String _kUpdateCheckMs = 'update_last_check_ms';
  static const String _kUpdateEtag = 'update_etag';
  static const String _kUpdateCache = 'update_cache_json';
  static const String _kUpdateSkip = 'update_skip_version';
  static const String _kUpdateAuto = 'update_auto_check';

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

  // ---- 画质细项（v0.2.1）：分辨率覆盖 / 帧率 / 自定义码率 ----------------
  // 三者与画质档位**相互独立**：换档位不清空这三项；分辨率选 `preset` 时
  // 才回落到档位自带宽度，码率 0 = 按档位/自动推算（见 `StreamPrefs`）。

  static int get streamFps => _prefs.getInt(_kStreamFps) ?? AppConfig.defaultFps;
  static Future<void> setStreamFps(int value) => _prefs.setInt(_kStreamFps, value);

  static String get streamResolution => _prefs.getString(_kStreamRes) ?? 'preset';
  static Future<void> setStreamResolution(String value) => _prefs.setString(_kStreamRes, value);

  /// `follow_local` 时缓存的像素宽（换了窗口尺寸会刷新）。
  static int get streamResolutionWidth => _prefs.getInt(_kStreamResWidth) ?? 0;
  static Future<void> setStreamResolutionWidth(int value) =>
      _prefs.setInt(_kStreamResWidth, value);

  static int get streamBitrate => _prefs.getInt(_kStreamBitrate) ?? 0;
  static Future<void> setStreamBitrate(int value) => _prefs.setInt(_kStreamBitrate, value);

  /// 当前画质参数（档位 + 细项合成），页面和面板共用同一个入口。
  static StreamPrefs get streamPrefs => StreamPrefs(
        preset: QualityPreset.fromValue(qualityValue),
        resolutionKey: streamResolution,
        resolutionWidth: streamResolutionWidth,
        fps: streamFps,
        bitrateOverride: streamBitrate,
        customBitrate: streamBitrate > 0,
      );

  static Future<void> saveStreamPrefs(StreamPrefs prefs) async {
    await setQualityValue(prefs.preset.value);
    await setStreamResolution(prefs.resolutionKey);
    if (prefs.resolutionWidth > 0) await setStreamResolutionWidth(prefs.resolutionWidth);
    await setStreamFps(prefs.fps);
    await setStreamBitrate(prefs.customBitrate ? prefs.bitrateOverride : 0);
  }

  /// 「允许其他设备控制本机」：默认开（登录即启动被控端），用户可关。
  static bool get allowBeControlled => _prefs.getBool(_kAllowBeControlled) ?? true;

  static Future<void> setAllowBeControlled(bool value) =>
      _prefs.setBool(_kAllowBeControlled, value);

  /// 远控中「剪贴板双向同步」开关，默认开（与官方一致）。
  ///
  /// 关掉后两个方向都不动作：既不把被控端复制的内容写进本机剪贴板
  /// （密码管理器场景用户会想关），也不再上行本机内容。
  static bool get clipboardSync => _prefs.getBool(_kClipboardSync) ?? true;

  static Future<void> setClipboardSync(bool value) => _prefs.setBool(_kClipboardSync, value);

  /// 自定义快捷键表（JSON）。只存与出厂默认不同的项 + 用户删掉的项。
  static String get shortcutsJson => _prefs.getString(_kShortcuts) ?? '';

  static Future<void> setShortcutsJson(String value) => _prefs.setString(_kShortcuts, value);

  /// 小窗模式参数（置顶/透明度/尺寸档）。只存偏好，不存窗口位置——
  /// 每次进入都从右下角重新摆，避免显示器换分辨率后窗口跑丢。
  static String get miniWindowJson => _prefs.getString(_kMiniWindow) ?? '';

  static Future<void> setMiniWindowJson(String value) =>
      _prefs.setString(_kMiniWindow, value);

  static bool get hasSession => token.isNotEmpty && deviceId.isNotEmpty;

  // ---- 自动升级状态 ----------------------------------------------------
  // 只存「上次检查时间 / ETag / 上次结果 JSON / 跳过的版本」，不存包体。
  // 包体落在 ~/.uu-remote/updates/（Windows 是 %LOCALAPPDATA%），见 updater.dart。

  /// 上次真正打到 GitHub 的时间（毫秒），用于 24h 节流。
  static int get updateLastCheckMs => _prefs.getInt(_kUpdateCheckMs) ?? 0;
  static Future<void> setUpdateLastCheckMs(int value) => _prefs.setInt(_kUpdateCheckMs, value);

  /// GitHub 的 ETag：命中 304 时不消耗匿名 60 次/小时的限额。
  static String get updateEtag => _prefs.getString(_kUpdateEtag) ?? '';
  static Future<void> setUpdateEtag(String value) => _prefs.setString(_kUpdateEtag, value);

  /// 上一次的 release JSON（原样缓存），离线/限流时仍能在「检查更新」里展示。
  static String get updateCacheJson => _prefs.getString(_kUpdateCache) ?? '';
  static Future<void> setUpdateCacheJson(String value) => _prefs.setString(_kUpdateCache, value);

  /// 用户点了「跳过此版本」的版本号。
  static String get updateSkipVersion => _prefs.getString(_kUpdateSkip) ?? '';
  static Future<void> setUpdateSkipVersion(String value) async {
    if (value.isEmpty) {
      await _prefs.remove(_kUpdateSkip);
    } else {
      await _prefs.setString(_kUpdateSkip, value);
    }
  }

  /// 启动时是否静默检查更新（默认开）。只检查、不下载。
  static bool get updateAutoCheck => _prefs.getBool(_kUpdateAuto) ?? true;
  static Future<void> setUpdateAutoCheck(bool value) => _prefs.setBool(_kUpdateAuto, value);

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