import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/agent_host.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../core/update_installer.dart';
import '../core/updater.dart';
import '../core/version.g.dart';

/// 打开更新对话框。[initial] 为 null 时自己发起一次强制检查。
Future<void> showUpdateDialog(BuildContext context, {UpdateCheckResult? initial}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext _) => UpdateDialog(initial: initial),
  );
}

/// 更新对话框：检查 → 展示新版本 → 下载（带进度）→ 安装 → 重启。
///
/// 刻意**不做静默替换**：远程桌面客户端在用户正在远控时被换掉会直接断链，
/// 所以这里永远是「用户点了才升级」。
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, this.initial});

  final UpdateCheckResult? initial;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  UpdateCheckResult? _result;
  bool _checking = false;
  bool _downloading = false;
  bool _installing = false;
  int _received = 0;
  int _total = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _result = widget.initial;
    if (_result == null || _result!.status == UpdateStatus.failed) {
      unawaited(_check());
    }
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    final UpdateCheckResult r = await Updater.check(force: true);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = r;
      if (r.status == UpdateStatus.failed) _error = r.message;
    });
  }

  Future<void> _startDownload() async {
    final UpdateInfo? info = _result?.info;
    if (info == null) return;
    setState(() {
      _downloading = true;
      _error = null;
      _received = 0;
      _total = info.asset.size;
    });
    try {
      final File archive = await Updater.download(
        info,
        onProgress: (int received, int total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _installing = true;
      });
      // 桌面端先把随包的 uu-agent 停掉：它的可执行文件就在要替换的目录里，
      // 不停会出现「旧 agent 还在跑 + 新实例又拉起一个」→ 同一 device 两条连接。
      if (!Platform.isAndroid) {
        try {
          await AgentHost.instance.stop();
        } catch (_) {
          // 停不掉也继续：换包本身不依赖它，新实例会重新拉起
        }
      }
      final InstallResult r = await UpdateInstaller.install(info, archive);
      if (!mounted) return;
      setState(() {
        _installing = false;
        _error = r.ok ? null : r.message;
        _result = r.ok
            ? UpdateCheckResult(status: UpdateStatus.upToDate, info: info, message: r.message)
            : _result;
      });
      if (r.ok) {
        Updater.cleanupExcept(info.version);
        if (r.restarting) {
          // 新版本已经拉起，等它接管后再退出，避免两个实例抢同一份配置
          await Future<void>.delayed(const Duration(milliseconds: 900));
          exit(0);
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _installing = false;
        _error = e is UpdateException ? e.message : '下载/安装失败：$e';
      });
    }
  }

  Future<void> _skip() async {
    final UpdateInfo? info = _result?.info;
    if (info != null) await Settings.setUpdateSkipVersion(info.version);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      titlePadding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.xl, AppSpace.xl, 0),
      contentPadding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.md, AppSpace.xl, 0),
      actionsPadding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.lg, AppSpace.lg),
      title: Row(
        children: <Widget>[
          const Icon(Icons.system_update_alt, size: 20, color: AppColors.accent),
          const SizedBox(width: AppSpace.sm),
          const Text('软件更新', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text('当前 v$kAppVersion', style: const TextStyle(fontSize: 12, color: AppColors.faint)),
        ],
      ),
      content: SizedBox(width: 460, child: _content()),
      actions: _actions(),
    );
  }

  Widget _content() {
    if (_checking) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpace.xl),
        child: Row(
          children: <Widget>[
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: AppSpace.md),
            Text('正在检查更新…', style: TextStyle(fontSize: 13.5, color: AppColors.muted)),
          ],
        ),
      );
    }

    if (_downloading || _installing) {
      final double p = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : 0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            _installing ? '正在安装…' : '正在下载 v${_result?.info?.version ?? ''}…',
            style: const TextStyle(fontSize: 13.5, color: AppColors.text),
          ),
          const SizedBox(height: AppSpace.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: _installing ? null : p,
              minHeight: 6,
              backgroundColor: AppColors.surfaceAlt,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            _installing
                ? '正在替换安装文件，完成后会自动重启'
                : '${_fmtMb(_received)} / ${_fmtMb(_total)}  ·  ${(p * 100).toStringAsFixed(0)}%',
            style: const TextStyle(fontSize: 12, color: AppColors.muted),
          ),
          if (!_installing) ...<Widget>[
            const SizedBox(height: AppSpace.sm),
            const Text(
              '下载完成后会校验 sha256，校验不通过不会安装。',
              style: TextStyle(fontSize: 11.5, color: AppColors.faint),
            ),
          ],
        ],
      );
    }

    final UpdateCheckResult? r = _result;
    final UpdateInfo? info = r?.info;

    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(_error!, style: const TextStyle(fontSize: 13, color: AppColors.danger, height: 1.5)),
          if (info != null) ...<Widget>[
            const SizedBox(height: AppSpace.md),
            _linkRow(info.htmlUrl),
          ],
        ],
      );
    }

    if (r == null) return const SizedBox(height: 8);

    if (r.status == UpdateStatus.upToDate) {
      return Text(
        r.message.isEmpty ? '已是最新版本' : r.message,
        style: const TextStyle(fontSize: 13.5, color: AppColors.text),
      );
    }

    if (r.status == UpdateStatus.unsupportedPlatform) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(r.message, style: const TextStyle(fontSize: 13, color: AppColors.text, height: 1.5)),
          if (info != null) ...<Widget>[
            const SizedBox(height: AppSpace.md),
            _linkRow(info.htmlUrl),
          ],
        ],
      );
    }

    // available / skipped：展示版本差异与更新说明
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Text('v$kAppVersion', style: TextStyle(fontSize: 13, color: AppColors.faint)),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpace.sm),
              child: Icon(Icons.arrow_forward, size: 14, color: AppColors.faint),
            ),
            Text(
              'v${info?.version ?? ''}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.accent),
            ),
            const Spacer(),
            if ((info?.asset.size ?? 0) > 0)
              Text(_fmtMb(info!.asset.size), style: const TextStyle(fontSize: 12, color: AppColors.faint)),
          ],
        ),
        const SizedBox(height: AppSpace.md),
        Container(
          constraints: const BoxConstraints(maxHeight: 220),
          padding: const EdgeInsets.all(AppSpace.md),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: AppColors.border),
          ),
          child: SingleChildScrollView(
            child: Text(
              (info?.notes.isNotEmpty ?? false) ? info!.notes : '（这个版本没有填写更新说明）',
              style: const TextStyle(fontSize: 12, height: 1.6, color: AppColors.muted),
            ),
          ),
        ),
        if (r.status == UpdateStatus.skipped) ...<Widget>[
          const SizedBox(height: AppSpace.sm),
          Text(
            '你之前跳过过这个版本。',
            style: TextStyle(fontSize: 11.5, color: AppColors.faint),
          ),
        ],
      ],
    );
  }

  List<Widget> _actions() {
    if (_downloading || _installing) {
      return <Widget>[TextButton(onPressed: null, child: const Text('请稍候'))];
    }
    if (_checking) {
      return <Widget>[TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消'))];
    }

    final UpdateCheckResult? r = _result;
    final bool canUpgrade = r != null && r.hasUpdate && r.info != null && _error == null;

    if (canUpgrade) {
      return <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('稍后')),
        TextButton(onPressed: _skip, child: const Text('跳过此版本')),
        FilledButton(
          onPressed: _startDownload,
          style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
          child: const Text('立即升级'),
        ),
      ];
    }

    return <Widget>[
      if (_error != null) TextButton(onPressed: _check, child: const Text('重试')),
      FilledButton(
        onPressed: () => Navigator.pop(context),
        style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
        child: const Text('知道了'),
      ),
    ];
  }

  Widget _linkRow(String url) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: AppColors.accent),
          ),
        ),
        IconButton(
          tooltip: '复制下载链接',
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          onPressed: () {
            Clipboard.setData(ClipboardData(text: url));
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('下载链接已复制')));
          },
          icon: const Icon(Icons.copy, color: AppColors.muted),
        ),
      ],
    );
  }

  static String _fmtMb(int bytes) {
    if (bytes <= 0) return '—';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
