import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'device_identity.dart';
import 'settings.dart';

/// 内置被控端的进程状态。
///
/// 只有桌面端（macOS / Windows / Linux）会拉起 `uu-agent`；移动端是纯控制端
/// （iOS/Android 不允许后台抓屏 + 注入输入），状态恒为 [unsupported]。
enum AgentHostState {
  /// 移动端 / 非桌面平台：不做被控。
  unsupported,

  /// 找不到随包分发的 `uu-agent`（打包时漏了）。
  missing,

  /// 用户关了「允许其他设备控制本机」，或未登录。
  stopped,

  /// 进程正在起。
  starting,

  /// 进程在跑（Agent 自己会重连 WS，这里只保证进程活着）。
  running,

  /// 进程异常退出，5 秒后自愈。
  restarting,

  /// 起不来（缺执行权限 / 架构不匹配 / 参数错误），不自动重试。
  failed,
}

/// 让 App 自带被控端：登录后把 `uu-agent` 作为子进程拉起来，退出登录即杀。
///
/// 为什么复用 `agent.py --token`：Agent 侧已有「App 一体化模式」——拿页面登录
/// token 调 `/api/v1/user/info` 校验，不重新走 `login/by_mobile`，所以**不会顶号**
/// （见 `agent/agent.py` 的 `run()`）。App 这边只负责进程生命周期：
///
/// ```
/// 登录成功 ──► start(--server, --token) ──► running
/// 退出登录 / 关开关 ──► SIGTERM ──► stopped
/// 进程异常退出 ──► 5s ──► 重新 start（Agent 内部也会自己重连，两层保险）
/// ```
///
/// 只允许桌面端：移动端系统层面做不到抓屏 + 输入注入，别硬做。
class AgentHost {
  AgentHost({this.binaryOverride});

  /// 全局单例。`UU_AGENT_BIN` 供 `flutter run` 调试时指向本地编译好的 uu-agent。
  static final AgentHost instance = AgentHost(
    binaryOverride: _envOverride(),
  );

  /// 进程重启间隔（要求：异常退出 5s 自愈）。
  static const Duration restartDelay = Duration(seconds: 5);

  /// 退出时先 SIGTERM 再强杀的超时。
  static const Duration killTimeout = Duration(seconds: 3);

  /// 调试用：显式指定 `uu-agent` 路径（`UU_AGENT_BIN` 或单测注入），跳过查找顺序。
  final String? binaryOverride;

  final ValueNotifier<AgentHostState> state =
      ValueNotifier<AgentHostState>(AgentHostState.stopped);

  /// 状态行副标题：错误原因 / 进程 PID / 缺失提示。
  final ValueNotifier<String?> detail = ValueNotifier<String?>(null);

  Process? _process;
  StreamSubscription<String>? _outSub;
  StreamSubscription<String>? _errSub;
  Timer? _restartTimer;

  String? _token;
  String? _server;

  /// 用户/会话层面「希望它跑」，用于区分主动 stop 和崩溃。
  bool _wanted = false;
  bool _starting = false;

  bool get isDesktopPlatform => !(Platform.isAndroid || Platform.isIOS);

  bool get isRunning => state.value == AgentHostState.running;

  /// 按当前会话 + 用户开关决定跑不跑。登录成功、冷启动、开关切换、改服务器都调它。
  ///
  /// [force] 为 true 时先停再起（改了服务器地址后必须重起才会连新地址）。
  Future<void> syncSession({bool force = false}) async {
    if (!isDesktopPlatform) {
      _set(AgentHostState.unsupported, '移动端只支持控制其他设备，不提供被控');
      return;
    }
    if (!Settings.hasSession) {
      await stop();
      return;
    }
    if (!Settings.allowBeControlled) {
      await stop();
      return;
    }
    if (force && (_process != null || _wanted)) {
      await stop(next: AgentHostState.stopped);
    }
    if (_process != null || _starting) return;
    await start(token: Settings.token, server: Settings.serverBase);
  }

  /// 启动子进程。已有进程时直接返回（幂等）。
  Future<void> start({required String token, required String server}) async {
    if (!isDesktopPlatform) {
      _set(AgentHostState.unsupported, '移动端只支持控制其他设备，不提供被控');
      return;
    }
    _wanted = true;
    _token = token;
    _server = server;
    if (_process != null || _starting) return;
    _restartTimer?.cancel();
    _restartTimer = null;

    final String? binary = _resolveBinary();
    if (binary == null) {
      _set(
        AgentHostState.missing,
        '被控端未随包分发：找不到 ${agentBinaryCandidates(
          platform: _platformName(),
          executablePath: Platform.resolvedExecutable,
        ).first}',
      );
      return;
    }

    _starting = true;
    _set(AgentHostState.starting, null);
    try {
      final Process process = await Process.start(
        binary,
        buildAgentArgs(token: token, server: server),
        workingDirectory: File(binary).parent.path,
      );
      _process = process;
      _bindLogs(process);
      // 先置 running 再挂 exitCode 监听：进程秒退时回调会抢在前面把状态改回
      // running，看起来像「明明崩了却显示运行中」。
      _set(AgentHostState.running, 'PID ${process.pid}');
      unawaited(process.exitCode.then((int code) => _onExit(process, code)));
    } catch (e) {
      _process = null;
      // 缺执行权限 / 架构不匹配（如 arm64 包跑在 x64 机器）/ 被 Gatekeeper 拦下
      _set(AgentHostState.failed, '被控端启动失败：$e');
    } finally {
      _starting = false;
    }
  }

  /// 主动停止：先 SIGTERM 给 Agent 收线机会，超时 SIGKILL。
  Future<void> stop({AgentHostState next = AgentHostState.stopped}) async {
    _wanted = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    final Process? process = _process;
    _process = null;
    await _outSub?.cancel();
    await _errSub?.cancel();
    _outSub = null;
    _errSub = null;

    if (process != null) {
      try {
        if (Platform.isWindows) {
          process.kill();
        } else {
          process.kill(ProcessSignal.sigterm);
        }
        await process.exitCode.timeout(killTimeout, onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        });
      } catch (_) {
        // 已经退出/无法 kill，忽略
      }
    }
    _set(next, null);
  }

  Future<void> dispose() async {
    await stop();
    state.dispose();
    detail.dispose();
  }

  // ------------------------------------------------------------ 进程事件

  void _onExit(Process process, int code) {
    // 已经被 stop() 接管（_process 已被清空）→ 不触发自愈
    if (!identical(_process, process)) return;
    _process = null;
    _outSub?.cancel();
    _errSub?.cancel();
    _outSub = null;
    _errSub = null;
    if (!_wanted) return;

    _set(AgentHostState.restarting, '被控端退出（code=$code），${restartDelay.inSeconds}s 后自动恢复');
    _restartTimer?.cancel();
    _restartTimer = Timer(restartDelay, () {
      final String? token = _token;
      final String? server = _server;
      if (!_wanted || token == null || server == null) return;
      unawaited(start(token: token, server: server));
    });
  }

  void _bindLogs(Process process) {
    _outSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) => _log(line));
    _errSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) => _log(line, isError: true));
  }

  /// stdout/stderr 全部转进统一日志；错误行同时留在 [detail] 里给设置页显示。
  void _log(String line, {bool isError = false}) {
    if (line.trim().isEmpty) return;
    debugPrint('[uu-agent${isError ? ':err' : ''}] $line');
    if (isError && _process != null) {
      // 不覆盖 PID：只在失败态显示原因
      if (state.value != AgentHostState.running) detail.value = line;
    }
  }

  // ------------------------------------------------------------ 路径解析

  String? _resolveBinary() {
    final String? override = binaryOverride;
    if (override != null && override.isNotEmpty) {
      return File(override).existsSync() ? override : null;
    }
    for (final String candidate in agentBinaryCandidates(
      platform: _platformName(),
      executablePath: Platform.resolvedExecutable,
    )) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  void _set(AgentHostState next, String? text) {
    state.value = next;
    detail.value = text;
  }

  static String _platformName() {
    if (Platform.isMacOS) return 'darwin';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  static String? _envOverride() {
    try {
      final String value = Platform.environment['UU_AGENT_BIN'] ?? '';
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  /// 状态的人话描述（设置页副标题）。
  static String describe(AgentHostState state) {
    switch (state) {
      case AgentHostState.unsupported:
        return '移动端只支持控制其他设备，不支持被控';
      case AgentHostState.missing:
        return '被控端未随包分发';
      case AgentHostState.stopped:
        return '已关闭，本机不会被远程控制';
      case AgentHostState.starting:
        return '正在启动被控端…';
      case AgentHostState.running:
        return '运行中，本机可被其他设备控制';
      case AgentHostState.restarting:
        return '异常退出，正在自动恢复…';
      case AgentHostState.failed:
        return '启动失败';
    }
  }
}

/// `uu-agent` 的查找顺序（只按打包形态约定，不猜）。
///
/// | 平台 | 位置 |
/// |---|---|
/// | macOS | `<X.app>/Contents/Resources/agent/uu-agent` |
/// | Windows | exe 同目录 `<dir>\uu-agent.exe`（兼容 `<dir>\agent\uu-agent.exe`） |
/// | Linux | `<bundle>/data/flutter_assets/agent/uu-agent` |
///
/// 纯函数，方便单测：不碰文件系统、不吃 Platform。
List<String> agentBinaryCandidates({
  required String platform,
  required String executablePath,
}) {
  const String name = 'uu-agent';
  final String sep = platform == 'windows' ? r'\' : '/';
  final String dir = _parentOf(executablePath, sep);
  switch (platform) {
    case 'darwin':
      // .../X.app/Contents/MacOS/X → .../X.app/Contents
      final String contents = _parentOf(dir, sep);
      return <String>[
        '$contents/Resources/agent/$name',
        '$dir/$name', // 非 bundle 的调试产物
      ];
    case 'windows':
      return <String>[
        '$dir\\$name.exe',
        '$dir\\agent\\$name.exe',
      ];
    case 'linux':
      return <String>[
        '$dir/data/flutter_assets/agent/$name',
        '$dir/$name',
      ];
    default:
      return const <String>[];
  }
}

/// 纯字符串取父目录：Windows 路径在 POSIX 上不能用 `File.parent` 解析，
/// 单测和跨平台判断都得靠这个。
String _parentOf(String path, String sep) {
  final String trimmed =
      path.endsWith(sep) ? path.substring(0, path.length - sep.length) : path;
  final int index = trimmed.lastIndexOf(sep);
  return index > 0 ? trimmed.substring(0, index) : trimmed;
}

/// `uu-agent` 的启动参数。
///
/// - `--token`：复用页面登录态（Agent 侧走 `/api/v1/user/info` 校验，不重新登录、不顶号）
/// - `--name`：与服务端登记的设备名保持一致
/// - `--insecure`：与 `ApiClient` / `SignalingClient` 的 `badCertificateCallback` 对齐，
///   否则自签证书的自托管服务端会让被控端起不来（正式版应与客户端一起改成证书固定）
List<String> buildAgentArgs({required String token, required String server}) {
  return <String>[
    '--server',
    server,
    '--token',
    token,
    '--name',
    DeviceIdentity.name,
    '--insecure',
  ];
}