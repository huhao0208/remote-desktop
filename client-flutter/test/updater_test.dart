import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/updater.dart';

/// 自动升级里最容易出错、又最适合单测的两块：版本比较与资产匹配。
/// 真机替换流程（ditto/robocopy/tar）没法在单测里验证，见 docs/auto-update.md §6。
void main() {
  group('compareSemver', () {
    test('基本大小关系', () {
      expect(compareSemver('0.2.0', '0.1.3'), greaterThan(0));
      expect(compareSemver('0.1.3', '0.2.0'), lessThan(0));
      expect(compareSemver('0.2.0', '0.2.0'), 0);
    });

    test('忽略 v 前缀与 build 号', () {
      expect(compareSemver('v0.2.0', '0.2.0'), 0);
      expect(compareSemver('0.2.0+37', '0.2.0'), 0);
      expect(compareSemver('0.2.0', '0.2.0+9'), 0);
    });

    test('位数不足按 0 补（0.2 视作 0.2.0）', () {
      expect(compareSemver('0.2', '0.2.0'), 0);
      expect(compareSemver('0.3', '0.2.9'), greaterThan(0));
    });

    test('两位数不进位错乱（0.10 > 0.9）', () {
      expect(compareSemver('0.10.0', '0.9.0'), greaterThan(0));
      expect(compareSemver('1.0.0', '0.99.99'), greaterThan(0));
    });

    test('预发布后缀按核心版本比（0.2.0-beta 视作 0.2.0）', () {
      expect(compareSemver('0.2.0-beta.1', '0.1.9'), greaterThan(0));
    });
  });

  group('clientAssetName', () {
    test('macOS 只认 arm64（CI 不产 x64 包）', () {
      expect(clientAssetName(arch: 'arm64', os: 'macos'),
          'uu-remote-client-flutter-macos.zip');
      expect(clientAssetName(arch: 'x64', os: 'macos'), isNull);
    });

    test('Windows / Linux 只认 x64', () {
      expect(clientAssetName(arch: 'x64', os: 'windows'),
          'uu-remote-client-flutter-windows.zip');
      expect(clientAssetName(arch: 'arm64', os: 'windows'), isNull);
      expect(clientAssetName(arch: 'x64', os: 'linux'),
          'uu-remote-client-flutter-linux.tar.gz');
      expect(clientAssetName(arch: 'arm64', os: 'linux'), isNull);
    });

    test('Android 按 ABI 选包，x86_64 不支持', () {
      expect(clientAssetName(arch: 'arm64', os: 'android'),
          'uu-remote-client-flutter-android-arm64-v8a.apk');
      expect(clientAssetName(arch: 'arm', os: 'android'),
          'uu-remote-client-flutter-android-armeabi-v7a.apk');
      expect(clientAssetName(arch: 'x64', os: 'android'), isNull);
    });

    test('未知平台返回 null（UI 走「去 Release 手动下载」）', () {
      expect(clientAssetName(arch: 'arm64', os: 'fuchsia'), isNull);
      expect(clientAssetName(arch: 'unknown', os: 'macos'), isNull);
    });
  });

  group('parseRelease', () {
    Map<String, dynamic> release({String? digest, List<String> assets = const <String>[]}) {
      return <String, dynamic>{
        'tag_name': 'v0.2.0',
        'body': '更新说明 [mandatory]',
        'html_url': 'https://github.com/huhao0208/remote-desktop/releases/tag/v0.2.0',
        'published_at': '2026-11-21T00:00:00Z',
        'assets': <Map<String, dynamic>>[
          for (final String name in assets)
            <String, dynamic>{
              'name': name,
              'browser_download_url': 'https://example.com/$name',
              'size': 12345,
              'digest': digest,
            },
        ],
      };
    }

    test('挑中本平台资产并解析 digest', () {
      final UpdateInfo? info = Updater.parseRelease(
        release(
          digest: 'sha256:ABCDEF0123',
          assets: <String>['uu-remote-macos-arm64.tar.gz', 'uu-remote-client-flutter-macos.zip'],
        ),
        'uu-remote-client-flutter-macos.zip',
      );
      expect(info, isNotNull);
      expect(info!.version, '0.2.0');
      expect(info.tag, 'v0.2.0');
      expect(info.asset.size, 12345);
      expect(info.asset.sha256, 'abcdef0123', reason: 'digest 前缀要去掉并转小写');
      expect(info.asset.verifiable, isTrue);
      expect(info.mandatory, isTrue);
    });

    test('没有 digest 时 sha256 为空，verifiable=false（下载会被拒）', () {
      final UpdateInfo? info = Updater.parseRelease(
        release(assets: <String>['uu-remote-client-flutter-macos.zip']),
        'uu-remote-client-flutter-macos.zip',
      );
      expect(info, isNotNull);
      expect(info!.asset.sha256, isNull);
      expect(info.asset.verifiable, isFalse);
    });

    test('资产里没有本平台包时返回 null', () {
      expect(
        Updater.parseRelease(
          release(assets: <String>['uu-remote-client-flutter-windows.zip']),
          'uu-remote-client-flutter-macos.zip',
        ),
        isNull,
      );
    });
  });

  test('UpdateInfo.isNewerThanCurrent 与 kAppVersion 联动', () {
    final UpdateInfo info = UpdateInfo(
      version: '9.9.9',
      tag: 'v9.9.9',
      notes: '',
      asset: const UpdateAsset(name: 'a', url: 'u', size: 1, sha256: 'x'),
      htmlUrl: 'h',
    );
    expect(info.isNewerThanCurrent, isTrue);
  });
}
