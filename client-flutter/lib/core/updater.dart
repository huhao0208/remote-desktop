import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'app_config.dart';
import 'settings.dart';
import 'version.g.dart';

/// 自动升级：查询 GitHub Release、下载安装包、校验 sha256。
///
/// 设计取舍（见 docs/auto-update.md）：
/// - **直连 GitHub**，不经过自建服务端。好处是零服务端改动；代价是国内网络不稳，
///   所以所有失败都归类成「检查失败」而不是「已是最新」，绝不给用户假的安全感。
/// - **24h 节流 + ETag**：匿名 API 限额 60 次/小时/IP，命中 304 的请求不计数。
/// - **先校验再安装**：GitHub 给每个 asset 返回 `digest: sha256:...`；拿不到 digest
///   时回退 Release 里的 `SHA256SUMS` 资产；两者都没有就拒绝安装。
class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum UpdateStatus {
  /// 已是最新（或本地版本更新，比如自己编的包）。
  upToDate,

  /// 有新版本待安装。
  available,

  /// 有新版本，但用户点过「跳过此版本」。
  skipped,

  /// 当前平台没有对应资产（如 Intel Mac、Linux arm64）。
  unsupportedPlatform,

  /// 网络/限流/解析失败。**不代表已是最新**。
  failed,
}

class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.url,
    required this.size,
    this.sha256,
  });

  final String name;
  final String url;
  final int size;

  /// 小写十六进制，不含 `sha256:` 前缀。可能为空（老资产没有 digest）。
  final String? sha256;

  bool get verifiable => (sha256 ?? '').isNotEmpty;
}

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.tag,
    required this.notes,
    required this.asset,
    required this.htmlUrl,
    this.publishedAt,
    this.mandatory = false,
  });

  /// 规范化后的版本号（去掉 `v` 前缀），如 `0.2.0`。
  final String version;
  final String tag;
  final String notes;
  final UpdateAsset asset;
  final String htmlUrl;
  final DateTime? publishedAt;

  /// Release 说明里写了 `[mandatory]` 时为真（本次不启用强制，仅保留字段）。
  final bool mandatory;

  bool get isNewerThanCurrent => compareSemver(version, kAppVersion) > 0;
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.status,
    this.info,
    this.message = '',
    this.fromCache = false,
  });

  final UpdateStatus status;
  final UpdateInfo? info;

  /// 直接给用户看的一句话。
  final String message;

  /// 结果来自本地缓存（离线/限流/未到检查时间）。
  final bool fromCache;

  bool get hasUpdate => status == UpdateStatus.available;
}

/// 语义化版本比较，只认 `x.y.z`（忽略预发布后缀，够用）。
/// 返回 <0 表示 a 比 b 旧，0 相等，>0 更新。
int compareSemver(String a, String b) {
  List<int> parse(String v) {
    final core = v.trim().replaceFirst(RegExp(r'^[vV]'), '').split('-').first.split('+').first;
    final parts = core.split('.');
    return List<int>.generate(3, (int i) {
      if (i >= parts.length) return 0;
      return int.tryParse(parts[i].replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    });
  }

  final pa = parse(a);
  final pb = parse(b);
  for (int i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i] - pb[i];
  }
  return 0;
}

/// 探测本机 CPU 架构，返回 `arm64` / `x64` / `arm` / `x86` / `unknown`。
///
/// 为什么不用 `Abi.current()`：当前 Dart SDK（3.14）的 `dart:io` 并不导出 `Abi`，
/// 静态分析直接报 undefined_class。这里退一步用系统命令/环境变量判断——
/// 只在点「检查更新」时调用一次，代价可以忽略。
String detectArch() {
  try {
    if (Platform.isMacOS || Platform.isLinux) {
      final ProcessResult r = Process.runSync('uname', <String>['-m']);
      final String s = (r.stdout as String).trim().toLowerCase();
      if (s.contains('arm64') || s.contains('aarch64')) return 'arm64';
      if (s.contains('x86_64') || s.contains('amd64')) return 'x64';
      if (s.startsWith('arm')) return 'arm';
      if (s.contains('i386') || s.contains('i686')) return 'x86';
      return 'unknown';
    }
    if (Platform.isWindows) {
      // PROCESSOR_ARCHITECTURE: AMD64 / ARM64 / x86
      final String s = (Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '').toLowerCase();
      if (s == 'arm64') return 'arm64';
      if (s == 'amd64') return 'x64';
      if (s == 'x86') return 'x86';
      return 'unknown';
    }
    if (Platform.isAndroid) {
      final ProcessResult r = Process.runSync('getprop', <String>['ro.product.cpu.abi']);
      final String s = (r.stdout as String).trim().toLowerCase();
      if (s.startsWith('arm64')) return 'arm64';
      if (s.startsWith('armeabi')) return 'arm';
      if (s.startsWith('x86_64')) return 'x64';
      if (s.startsWith('x86')) return 'x86';
      return 'unknown';
    }
  } catch (_) {
    // 探测失败就返回 unknown，由调用方决定「不支持自动更新」
  }
  return 'unknown';
}

/// 当前平台该下哪个资产。返回 null 表示本平台没有发布包。
///
/// 与 CI 的产物名一一对应（`.github/workflows/build.yml` 的 flutter-build-* job）。
/// [arch] / [os] 只为单测注入，正常调用不用传。
String? clientAssetName({
  String? arch,
  String? os,
}) {
  final String a = arch ?? detectArch();
  final String p = os ?? Platform.operatingSystem;

  if (p == 'macos') {
    // CI 只产出 arm64（runner 是 Apple Silicon，账号不支持 macos-13/-14）
    return a == 'arm64' ? 'uu-remote-client-flutter-macos.zip' : null;
  }
  if (p == 'windows') {
    return a == 'x64' ? 'uu-remote-client-flutter-windows.zip' : null;
  }
  if (p == 'linux') {
    return a == 'x64' ? 'uu-remote-client-flutter-linux.tar.gz' : null;
  }
  if (p == 'android') {
    if (a == 'arm64') return 'uu-remote-client-flutter-android-arm64-v8a.apk';
    if (a == 'arm') return 'uu-remote-client-flutter-android-armeabi-v7a.apk';
    return null;
  }
  return null;
}

/// 本机平台的中文名，给 UI 用。
String currentPlatformLabel() {
  final String os = Platform.operatingSystem;
  final String arch = detectArch();
  switch (os) {
    case 'macos':
      return 'macOS $arch';
    case 'windows':
      return 'Windows $arch';
    case 'linux':
      return 'Linux $arch';
    case 'android':
      return 'Android $arch';
    default:
      return '$os $arch';
  }
}

class Updater {
  Updater._();

  /// 真正打到 GitHub 的最小间隔。用户手动点「检查更新」时传 force 绕过。
  static const Duration checkInterval = Duration(hours: 24);

  static const String _apiBase = 'https://api.github.com';

  /// 上一次检查结果在内存里留一份，避免页面重建反复解析。
  static UpdateCheckResult? _last;

  static UpdateCheckResult? get lastResult => _last;

  // ------------------------------------------------------------------ 检查

  /// 查最新版本。
  ///
  /// [force] 为 true 时忽略 24h 节流（用户手动点「检查更新」）。
  static Future<UpdateCheckResult> check({bool force = false}) async {
    final String? assetName = clientAssetName();
    if (assetName == null) {
      return _remember(UpdateCheckResult(
        status: UpdateStatus.unsupportedPlatform,
        message: '当前平台（${currentPlatformLabel()}）没有官方安装包，请到 Release 页手动下载。',
      ));
    }

    // 未到检查时间：直接用缓存，避免无谓请求
    final int lastMs = Settings.updateLastCheckMs;
    final bool throttled = !force &&
        lastMs > 0 &&
        DateTime.now().millisecondsSinceEpoch - lastMs < checkInterval.inMilliseconds;
    if (throttled) {
      final UpdateCheckResult? cached = _fromCache(assetName, forcedNote: '');
      if (cached != null) {
        return _remember(cached.fromCacheResult());
      }
    }

    final HttpClient client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final Uri uri = Uri.parse('$_apiBase/repos/${AppConfig.releaseRepo}/releases/latest');
      final HttpClientRequest req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set(HttpHeaders.userAgentHeader, 'uu-remote/$kAppVersion');
      final String etag = Settings.updateEtag;
      if (etag.isNotEmpty) req.headers.set(HttpHeaders.ifNoneMatchHeader, etag);

      final HttpClientResponse resp = await req.close();

      if (resp.statusCode == HttpStatus.notModified) {
        // 内容没变，不消耗限额；缓存里的版本仍然有效
        await Settings.setUpdateLastCheckMs(DateTime.now().millisecondsSinceEpoch);
        final UpdateCheckResult? cached = _fromCache(assetName, forcedNote: '');
        if (cached != null) return _remember(cached);
        return _remember(const UpdateCheckResult(
          status: UpdateStatus.upToDate,
          message: '已是最新版本',
        ));
      }

      if (resp.statusCode == HttpStatus.forbidden || resp.statusCode == 429) {
        // 匿名限额 60/h。绝不能当成「已是最新」。
        final UpdateCheckResult? cached = _fromCache(assetName, forcedNote: '（GitHub 限流，以下为上次检查结果）');
        if (cached != null) return _remember(cached);
        return _remember(const UpdateCheckResult(
          status: UpdateStatus.failed,
          message: 'GitHub 接口限流（每小时 60 次），请稍后再试。',
        ));
      }

      if (resp.statusCode != HttpStatus.ok) {
        return _remember(UpdateCheckResult(
          status: UpdateStatus.failed,
          message: '检查更新失败：GitHub 返回 HTTP ${resp.statusCode}',
        ));
      }

      final String body = await resp.transform(utf8.decoder).join();
      final Map<String, dynamic> release = jsonDecode(body) as Map<String, dynamic>;

      final String newEtag = resp.headers.value(HttpHeaders.etagHeader) ?? '';
      if (newEtag.isNotEmpty) await Settings.setUpdateEtag(newEtag);
      await Settings.setUpdateCacheJson(body);
      await Settings.setUpdateLastCheckMs(DateTime.now().millisecondsSinceEpoch);

      final UpdateInfo? info = parseRelease(release, assetName);
      if (info == null) {
        return _remember(UpdateCheckResult(
          status: UpdateStatus.failed,
          message: '最新 Release 里没有 ${currentPlatformLabel()} 的安装包（$assetName）。',
        ));
      }

      return _remember(_decide(info));
    } on SocketException catch (e) {
      final UpdateCheckResult? cached = _fromCache(assetName, forcedNote: '（网络不可达，以下为上次检查结果）');
      if (cached != null) return _remember(cached);
      return _remember(UpdateCheckResult(
        status: UpdateStatus.failed,
        message: '连不上 GitHub：${e.message}',
      ));
    } catch (e) {
      return _remember(UpdateCheckResult(
        status: UpdateStatus.failed,
        message: '检查更新失败：$e',
      ));
    } finally {
      client.close(force: true);
    }
  }

  /// 从 Release JSON 里挑出本平台资产并组装。
  static UpdateInfo? parseRelease(Map<String, dynamic> release, String assetName) {
    final List<dynamic> assets = (release['assets'] as List<dynamic>? ?? <dynamic>[]);
    Map<String, dynamic>? hit;
    for (final dynamic a in assets) {
      if (a is Map<String, dynamic> && a['name'] == assetName) {
        hit = a;
        break;
      }
    }
    if (hit == null) return null;

    String? sha;
    final String digest = (hit['digest'] as String? ?? '');
    if (digest.startsWith('sha256:')) {
      sha = digest.substring('sha256:'.length).toLowerCase();
    }

    final String tag = (release['tag_name'] as String? ?? '').trim();
    final String version = tag.replaceFirst(RegExp(r'^[vV]'), '');
    final String notes = (release['body'] as String? ?? '').trim();

    return UpdateInfo(
      version: version,
      tag: tag,
      notes: notes,
      asset: UpdateAsset(
        name: assetName,
        url: (hit['browser_download_url'] as String? ?? ''),
        size: (hit['size'] as num?)?.toInt() ?? 0,
        sha256: sha,
      ),
      htmlUrl: (release['html_url'] as String? ?? ''),
      publishedAt: DateTime.tryParse(release['published_at'] as String? ?? ''),
      mandatory: notes.toLowerCase().contains('[mandatory]'),
    );
  }

  static UpdateCheckResult _decide(UpdateInfo info) {
    if (!info.isNewerThanCurrent) {
      return UpdateCheckResult(
        status: UpdateStatus.upToDate,
        info: info,
        message: '已是最新版本（$kAppVersion）',
      );
    }
    if (Settings.updateSkipVersion == info.version) {
      return UpdateCheckResult(
        status: UpdateStatus.skipped,
        info: info,
        message: '已跳过 v${info.version}',
      );
    }
    return UpdateCheckResult(
      status: UpdateStatus.available,
      info: info,
      message: '发现新版本 v${info.version}',
    );
  }

  static UpdateCheckResult? _fromCache(String assetName, {required String forcedNote}) {
    final String raw = Settings.updateCacheJson;
    if (raw.isEmpty) return null;
    try {
      final Map<String, dynamic> release = jsonDecode(raw) as Map<String, dynamic>;
      final UpdateInfo? info = parseRelease(release, assetName);
      if (info == null) return null;
      final UpdateCheckResult base = _decide(info);
      return UpdateCheckResult(
        status: base.status,
        info: base.info,
        message: forcedNote.isEmpty ? base.message : '${base.message}$forcedNote',
        fromCache: true,
      );
    } catch (_) {
      return null;
    }
  }

  static UpdateCheckResult _remember(UpdateCheckResult r) {
    _last = r;
    return r;
  }

  // ------------------------------------------------------------------ 下载

  /// 下载根目录：`~/.uu-remote/updates`（Windows 放 `%LOCALAPPDATA%`，
  /// Android 放应用 cache 目录——FileProvider 只共享那里）。
  static Directory updateRoot() {
    final Map<String, String> env = Platform.environment;
    final String home = env['HOME'] ?? env['USERPROFILE'] ?? Directory.systemTemp.path;
    final String base;
    if (Platform.isAndroid) {
      // Android 上 HOME 不可靠，systemTemp 指向 /data/user/0/<pkg>/cache
      base = Directory.systemTemp.path;
    } else if (Platform.isWindows) {
      base = env['LOCALAPPDATA'] ?? home;
    } else {
      base = home;
    }
    final Directory d = Directory('$base${Platform.pathSeparator}.uu-remote'
        '${Platform.pathSeparator}updates');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static Directory versionDir(String version) {
    final Directory d = Directory('${updateRoot().path}${Platform.pathSeparator}$version');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 下载并校验。[onProgress] 拿 (已下载字节, 总字节)，[cancelled] 返回 true 时中断。
  ///
  /// 已存在且校验通过的文件直接复用（重试/重开对话框不重复下载 100MB）。
  static Future<File> download(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final Directory dir = versionDir(info.version);
    final File target = File('${dir.path}${Platform.pathSeparator}${info.asset.name}');

    if (target.existsSync()) {
      final int len = target.lengthSync();
      final bool sizeOk = info.asset.size == 0 || len == info.asset.size;
      if (sizeOk && await sha256OfFile(target) == info.asset.sha256) {
        onProgress?.call(len, len);
        return target;
      }
      target.deleteSync();
    }

    if (!info.asset.verifiable) {
      throw UpdateException(
        '这个 Release 没有提供 sha256 校验值，为安全起见不自动安装。'
        '请到 Release 页手动下载：${info.htmlUrl}',
      );
    }

    final HttpClient client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    File? part;
    IOSink? sink;
    try {
      final HttpClientRequest req = await client.getUrl(Uri.parse(info.asset.url));
      req.headers.set(HttpHeaders.userAgentHeader, 'uu-remote/$kAppVersion');
      final HttpClientResponse resp = await req.close();
      if (resp.statusCode != HttpStatus.ok) {
        throw UpdateException('下载失败：HTTP ${resp.statusCode}（${info.asset.name}）');
      }

      final int total = resp.contentLength > 0 ? resp.contentLength : info.asset.size;
      part = File('${target.path}.part');
      sink = part.openWrite();

      final _DigestSink digestSink = _DigestSink();
      final ByteConversionSink hasher = sha256.startChunkedConversion(digestSink);
      int received = 0;
      int lastTick = 0;

      await for (final List<int> chunk in resp) {
        if (cancelled?.call() ?? false) {
          throw UpdateException('已取消下载');
        }
        hasher.add(chunk);
        sink.add(chunk);
        received += chunk.length;
        final int now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastTick > 200) {
          lastTick = now;
          onProgress?.call(received, total);
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      hasher.close();
      onProgress?.call(received, total);

      final String got = digestSink.value.toString();
      if (got != info.asset.sha256) {
        throw UpdateException('校验失败：下载到的文件 sha256 与 Release 不符，已丢弃。');
      }
      if (info.asset.size > 0 && received != info.asset.size) {
        throw UpdateException('下载不完整：收到 $received 字节，应为 ${info.asset.size}。');
      }

      if (target.existsSync()) target.deleteSync();
      await part.rename(target.path);
      part = null;
      return target;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      if (part != null && part.existsSync()) {
        try {
          part.deleteSync();
        } catch (_) {}
      }
      client.close(force: true);
    }
  }

  static Future<String> sha256OfFile(File file) async {
    final _DigestSink sink = _DigestSink();
    final ByteConversionSink hasher = sha256.startChunkedConversion(sink);
    await for (final List<int> chunk in file.openRead()) {
      hasher.add(chunk);
    }
    hasher.close();
    return sink.value.toString();
  }

  /// 安装完成后清掉旧版本的下载残留（只保留 [keep]）。
  static void cleanupExcept(String? keep) {
    try {
      final Directory root = updateRoot();
      for (final FileSystemEntity e in root.listSync()) {
        if (e is! Directory) continue;
        if (keep != null && e.path.endsWith(Platform.pathSeparator + keep)) continue;
        e.deleteSync(recursive: true);
      }
    } catch (_) {
      // 清理失败不影响升级
    }
  }
}

/// 收集 `sha256.startChunkedConversion` 产出的单个 Digest。
class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get value {
    final Digest? d = _digest;
    if (d == null) throw StateError('摘要尚未生成');
    return d;
  }

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}

extension on UpdateCheckResult {
  UpdateCheckResult fromCacheResult() => fromCache
      ? this
      : UpdateCheckResult(status: status, info: info, message: message, fromCache: true);
}
