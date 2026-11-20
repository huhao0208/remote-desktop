import 'dart:io';

import 'package:flutter/services.dart';

import 'updater.dart';

/// 安装结果：成功后调用方应当退出进程（重启由 helper 脚本或 open 完成）。
class InstallResult {
  const InstallResult(this.ok, this.message, {this.restarting = false});

  final bool ok;
  final String message;

  /// true 表示新版本已被拉起，当前进程应该立刻退出。
  final bool restarting;

  static InstallResult failure(String msg) => InstallResult(false, msg);
  static InstallResult success(String msg, {bool restarting = true}) =>
      InstallResult(true, msg, restarting: restarting);
}

/// 把下载好的包换到正在运行的安装位置上。
///
/// 三种桌面平台的共同难点：**运行中的可执行文件不能被覆盖**。
/// - macOS：整个 `.app` 是个目录，改名旧包再放新包即可（改名不影响运行中的进程）。
/// - Linux：可执行文件可以原地覆盖（inode 替换），但进程仍跑旧 inode，必须重启。
/// - Windows：运行中的 exe 不能覆盖也不能删，但**可以改名**；所以 helper 先改名再 robocopy。
///
/// 所有平台都走「先落 staging → 校验 → 换位 → 拉起新版」的顺序，
/// 任何一步失败都要把旧版本放回去，绝不让用户落在一个半装状态。
class UpdateInstaller {
  UpdateInstaller._();

  static const MethodChannel _androidChannel = MethodChannel('uu/installer');

  static Future<InstallResult> install(UpdateInfo info, File archive) async {
    try {
      if (Platform.isMacOS) return await _installMacOS(info, archive);
      if (Platform.isWindows) return await _installWindows(info, archive);
      if (Platform.isLinux) return await _installLinux(info, archive);
      if (Platform.isAndroid) return await _installAndroid(info, archive);
      return InstallResult.failure('当前平台不支持自动安装，请到 ${info.htmlUrl} 手动下载。');
    } catch (e) {
      return InstallResult.failure('安装失败：$e\n可到 ${info.htmlUrl} 手动下载。');
    }
  }

  // ---------------------------------------------------------------- macOS

  static Future<InstallResult> _installMacOS(UpdateInfo info, File archive) async {
    // .../uu_remote.app/Contents/MacOS/uu_remote → 上三级才是 .app
    final File exe = File(Platform.resolvedExecutable);
    final Directory appBundle = exe.parent.parent.parent;
    if (!appBundle.path.endsWith('.app')) {
      return InstallResult.failure('无法定位 .app 包（当前可执行文件在 ${exe.path}），请手动下载。');
    }

    final Directory staging = _freshStaging(info.version);
    final ProcessResult unzip =
        await Process.run('ditto', <String>['-x', '-k', archive.path, staging.path]);
    if (unzip.exitCode != 0) {
      return InstallResult.failure('解压失败：${unzip.stderr}');
    }

    final Directory? newApp = _findApp(staging);
    if (newApp == null) {
      return InstallResult.failure('压缩包里没有 .app，可能下载错了资产。');
    }

    // 版本必须对得上，避免把别的版本装进去
    final ProcessResult plist = await Process.run('/usr/libexec/PlistBuddy', <String>[
      '-c',
      'Print :CFBundleShortVersionString',
      '${newApp.path}/Contents/Info.plist',
    ]);
    final String gotVersion = (plist.stdout as String).trim();
    if (plist.exitCode != 0 || gotVersion != info.version) {
      return InstallResult.failure(
        '包内版本（$gotVersion）与目标版本（${info.version}）不一致，已中止。',
      );
    }

    // 新包必须是签名有效的：ad-hoc 也算，但绝不能是破签名的包
    final ProcessResult verify =
        await Process.run('codesign', <String>['--verify', '--deep', '--strict', newApp.path]);
    if (verify.exitCode != 0) {
      return InstallResult.failure('新包的代码签名校验不通过，已中止：${verify.stderr}');
    }

    final String targetPath = appBundle.path;
    final String backupPath = '$targetPath.bak';

    // 旧备份先清掉（上一次升级残留）
    if (Directory(backupPath).existsSync()) {
      Directory(backupPath).deleteSync(recursive: true);
    }

    final ProcessResult movedOld = await Process.run('mv', <String>[targetPath, backupPath]);
    if (movedOld.exitCode != 0) {
      return InstallResult.failure(
        '没有权限替换 ${appBundle.path}（装到 /Applications 时请确认是当前用户安装的）：'
        '${movedOld.stderr}',
      );
    }

    final ProcessResult movedNew = await Process.run('mv', <String>[newApp.path, targetPath]);
    if (movedNew.exitCode != 0) {
      // 回滚：把旧包放回去
      await Process.run('mv', <String>[backupPath, targetPath]);
      return InstallResult.failure('替换失败，已回滚到原版本：${movedNew.stderr}');
    }

    // 自己下载的文件本来没有 quarantine，这里再兜一遍（比如用户手动替换过）
    await Process.run('xattr', <String>['-dr', 'com.apple.quarantine', targetPath]);

    final ProcessResult open = await Process.run('open', <String>['-n', targetPath]);
    if (open.exitCode != 0) {
      return InstallResult.success(
        '已安装 v${info.version}，但自动启动失败，请手动打开：$targetPath',
        restarting: false,
      );
    }
    return InstallResult.success('已更新到 v${info.version}，正在重启');
  }

  // -------------------------------------------------------------- Windows

  static Future<InstallResult> _installWindows(UpdateInfo info, File archive) async {
    final File exe = File(Platform.resolvedExecutable);
    final Directory installDir = exe.parent;

    final Directory staging = _freshStaging(info.version);
    final ProcessResult unzip = await Process.run('powershell', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Expand-Archive -LiteralPath \'${_psEscape(archive.path)}\' '
          '-DestinationPath \'${_psEscape(staging.path)}\' -Force',
    ]);
    if (unzip.exitCode != 0) {
      return InstallResult.failure('解压失败：${unzip.stderr}');
    }

    final String exeName = exe.uri.pathSegments.last; // uu_remote.exe
    if (!File('${staging.path}\\$exeName').existsSync()) {
      return InstallResult.failure('压缩包里没有 $exeName，可能下载错了资产。');
    }

    final Directory cache = Updater.versionDir(info.version);
    final File script = File('${cache.path}\\uu-update-${DateTime.now().millisecondsSinceEpoch}.ps1');

    // helper 要在主进程退出后干活，所以只能写成独立脚本再 detached 启动。
    // robocopy /E /IS：覆盖同名文件（/IS 连「相同」也覆盖，避免时间戳判断漏掉）。
    script.writeAsStringSync('''
\$ErrorActionPreference = 'Continue'
\$procId = $pid
\$src = '${_psEscape(staging.path)}'
\$dst = '${_psEscape(installDir.path)}'
\$exeName = '${_psEscape(exeName)}'
for (\$i = 0; \$i -lt 120; \$i++) {
  if (-not (Get-Process -Id \$procId -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 500
}
Start-Sleep -Milliseconds 800
# 运行中的 exe 不能覆盖删除，但可以改名——先挪开再拷新的
\$old = Join-Path \$dst (\$exeName + '.old')
if (Test-Path \$old) { Remove-Item -LiteralPath \$old -Force -ErrorAction SilentlyContinue }
try { Move-Item -LiteralPath (Join-Path \$dst \$exeName) -Destination \$old -Force -ErrorAction SilentlyContinue } catch {}
robocopy \$src \$dst /E /IS /NFL /NDL /NJH /NJS /R:2 /W:1 | Out-Null
Start-Process -FilePath (Join-Path \$dst \$exeName)
Remove-Item -LiteralPath \$PSCommandPath -Force -ErrorAction SilentlyContinue
''');

    await Process.start(
      'powershell',
      <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
      ],
      mode: ProcessStartMode.detached,
    );

    return InstallResult.success('已下载 v${info.version}，应用退出后自动替换并重启');
  }

  // ---------------------------------------------------------------- Linux

  static Future<InstallResult> _installLinux(UpdateInfo info, File archive) async {
    final File exe = File(Platform.resolvedExecutable);
    final Directory bundleDir = exe.parent;

    final Directory staging = _freshStaging(info.version);
    final ProcessResult untar =
        await Process.run('tar', <String>['-xzf', archive.path, '-C', staging.path]);
    if (untar.exitCode != 0) {
      return InstallResult.failure('解压失败：${untar.stderr}');
    }

    final String exeName = exe.uri.pathSegments.last;
    if (!File('${staging.path}/$exeName').existsSync()) {
      return InstallResult.failure('压缩包里没有 $exeName，可能下载错了资产。');
    }

    final File script = File(
      '${Directory.systemTemp.path}/uu-update-${DateTime.now().millisecondsSinceEpoch}.sh',
    );
    script.writeAsStringSync('''
#!/bin/sh
PID=$pid
SRC='${staging.path.replaceAll("'", "'\\''")}'
DST='${bundleDir.path.replaceAll("'", "'\\''")}'
EXE='$exeName'
while kill -0 "\$PID" 2>/dev/null; do sleep 0.5; done
cp -a "\$SRC"/. "\$DST"/ || exit 1
chmod +x "\$DST/\$EXE" 2>/dev/null
rm -rf "\$SRC"
cd "\$DST" && exec "\$DST/\$EXE" >/dev/null 2>&1 &
''');
    await Process.run('chmod', <String>['+x', script.path]);

    await Process.start(
      '/bin/sh',
      <String>[script.path],
      mode: ProcessStartMode.detached,
    );

    return InstallResult.success('已下载 v${info.version}，应用退出后自动替换并重启');
  }

  // --------------------------------------------------------------- Android

  static Future<InstallResult> _installAndroid(UpdateInfo info, File archive) async {
    // 覆盖安装前提：新 APK 与已装 APK 签名一致。CI 若仍用 debug key，
    // 换了构建机就会「应用未安装」——见 docs/auto-update.md §4。
    try {
      final bool? opened = await _androidChannel.invokeMethod<bool>(
        'installApk',
        <String, dynamic>{'path': archive.path},
      );
      if (opened == true) {
        return InstallResult.success('已拉起系统安装器，请按提示完成安装', restarting: false);
      }
      return InstallResult.failure('系统没有打开安装器，请到 ${info.htmlUrl} 手动下载。');
    } on PlatformException catch (e) {
      return InstallResult.failure(
        '拉起安装器失败：${e.message ?? e.code}。'
        '请在系统设置里允许「安装未知应用」，或到 ${info.htmlUrl} 手动下载。',
      );
    } on MissingPluginException {
      return InstallResult.failure('当前构建不支持应用内安装，请到 ${info.htmlUrl} 手动下载。');
    }
  }

  // ----------------------------------------------------------------- 工具

  static Directory _freshStaging(String version) {
    final Directory d = Directory('${Updater.versionDir(version).path}${Platform.pathSeparator}extract');
    if (d.existsSync()) d.deleteSync(recursive: true);
    d.createSync(recursive: true);
    return d;
  }

  static Directory? _findApp(Directory dir) {
    for (final FileSystemEntity e in dir.listSync()) {
      if (e is Directory && e.path.endsWith('.app')) return e;
    }
    return null;
  }

  /// PowerShell 单引号字符串里，单引号要写两次。
  static String _psEscape(String s) => s.replaceAll("'", "''");
}
