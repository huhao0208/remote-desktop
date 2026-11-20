import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/agent_host.dart';

void main() {
  group('uu-agent 查找顺序', () {
    test('macOS：从 Contents/MacOS 推到 Contents/Resources/agent', () {
      final List<String> paths = agentBinaryCandidates(
        platform: 'darwin',
        executablePath: '/Applications/UU Remote.app/Contents/MacOS/uu_remote',
      );
      expect(paths.first, '/Applications/UU Remote.app/Contents/Resources/agent/uu-agent');
      expect(paths, hasLength(2));
    });

    test('Windows：exe 同目录优先，兼容 agent 子目录', () {
      final List<String> paths = agentBinaryCandidates(
        platform: 'windows',
        executablePath: r'C:\Program Files\UU\uu_remote.exe',
      );
      expect(paths.first, r'C:\Program Files\UU\uu-agent.exe');
      expect(paths.last, r'C:\Program Files\UU\agent\uu-agent.exe');
    });

    test('Linux：bundle/data/flutter_assets/agent', () {
      final List<String> paths = agentBinaryCandidates(
        platform: 'linux',
        executablePath: '/opt/uu/uu_remote',
      );
      expect(paths.first, '/opt/uu/data/flutter_assets/agent/uu-agent');
    });

    test('未知平台不猜路径', () {
      expect(agentBinaryCandidates(platform: 'fuchsia', executablePath: '/x'), isEmpty);
    });
  });

  group('uu-agent 启动参数', () {
    test('复用页面 token，不传 --mobile（不重新登录、不顶号）', () {
      final List<String> args = buildAgentArgs(
        token: 'page-token',
        server: 'https://47-251-105-202.sslip.io:8444',
      );
      expect(args[0], '--server');
      expect(args[1], 'https://47-251-105-202.sslip.io:8444');
      final int tokenAt = args.indexOf('--token');
      expect(tokenAt, greaterThan(0));
      expect(args[tokenAt + 1], 'page-token');
      expect(args, isNot(contains('--mobile')));
      // 自签服务端：与客户端 badCertificateCallback 对齐
      expect(args, contains('--insecure'));
    });
  });

  group('AgentHost 状态', () {
    test('初始为 stopped，桌面端（测试跑在 VM 上）认为自己是桌面', () {
      final AgentHost host = AgentHost();
      expect(host.state.value, AgentHostState.stopped);
      expect(host.isDesktopPlatform, isTrue);
      // 未 start 时不会有进程
      expect(host.isRunning, isFalse);
    });

    test('每个状态都有人话描述', () {
      for (final AgentHostState state in AgentHostState.values) {
        expect(AgentHost.describe(state), isNotEmpty, reason: '$state');
      }
      expect(AgentHost.describe(AgentHostState.missing), contains('未随包分发'));
    });

    test('移动端不提供被控（Platform 判定）', () {
      // 本机是桌面，只能间接验证：非 Android/iOS 时 isDesktopPlatform 为真
      final bool mobile = Platform.isAndroid || Platform.isIOS;
      expect(AgentHost().isDesktopPlatform, !mobile);
    });
  });

  // 真起子进程：验证「拉起 → running → 主动停止」和「崩溃 → restarting」
  // 这两条生命周期，不需要真的 uu-agent（用 shell 脚本冒充）。
  group('AgentHost 生命周期（真实子进程）', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('uu_agent_test');
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<String> fakeAgent(String body) async {
      final File script = File('${tmp.path}/uu-agent');
      await script.writeAsString('#!/bin/sh\n$body\n');
      await Process.run('chmod', <String>['+x', script.path]);
      return script.path;
    }

    /// 进程退出是异步的，不能靠固定 sleep（CI 机器慢的时候会抖）。
    Future<void> waitForState(AgentHost host, AgentHostState want) async {
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        if (host.state.value == want) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      fail('等 $want 超时，当前 ${host.state.value}');
    }

    test('start → running，stop → stopped（且进程真的退出）', () async {
      final String bin = await fakeAgent('echo "agent up"\nsleep 30');
      final AgentHost host = AgentHost(binaryOverride: bin);
      addTearDown(host.dispose);

      await host.start(token: 't', server: 'https://x:8443');
      expect(host.state.value, AgentHostState.running);
      expect(host.detail.value, contains('PID'));
      expect(await File(bin).exists(), isTrue);

      await host.stop();
      expect(host.state.value, AgentHostState.stopped);
      expect(host.isRunning, isFalse);
    });

    test('进程异常退出 → restarting（并已排好 5s 自愈）', () async {
      final String bin = await fakeAgent('exit 3');
      final AgentHost host = AgentHost(binaryOverride: bin);
      addTearDown(host.dispose);

      await host.start(token: 't', server: 'https://x:8443');
      // 秒退的进程可能比 start() 返回还快，等状态自己翻过去
      await waitForState(host, AgentHostState.restarting);
      expect(host.detail.value, contains('5s'));

      await host.stop();
      expect(host.state.value, AgentHostState.stopped);
    });

    test('找不到二进制 → missing，不假装在跑', () async {
      final AgentHost host = AgentHost(binaryOverride: '${tmp.path}/nope');
      addTearDown(host.dispose);
      await host.start(token: 't', server: 'https://x:8443');
      expect(host.state.value, AgentHostState.missing);
      expect(host.detail.value, contains('未随包分发'));
    });
  });
}