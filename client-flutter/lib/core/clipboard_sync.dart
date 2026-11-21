import 'package:flutter/services.dart';

/// 下游（被控端 → 本机）写入结果：调用方据此决定是否提示用户。
///
/// 为什么要把「跳过」的理由分得这么细：剪贴板同步是后台轮询触发的，
/// 空内容/同内容是**正常**的常态（每次轮询都会遇到），提示了就变噪音；
/// 只有超长、开关关闭这类用户可感知的情况才值得 toast。所以结果不能只用
/// `bool`，否则 UI 无法区分「没事发生」和「同步失败」。
enum ClipboardApplyResult {
  /// 已写入本机系统剪贴板。
  applied,

  /// 与本机已知文本相同（含上行回声），无需重复写入。
  skippedSame,

  /// 同步开关关闭。
  skippedOff,

  /// 空串/全空白（或本机剪贴板写入失败，见 [ClipboardSync.applyRemote]）。
  skippedEmpty,

  /// 超过 `maxChars` 上限，**不做静默截断**——截断会把半截代码/密钥粘给用户。
  skippedTooLong,
}

/// 远控剪贴板文本双向同步的客户端半边（纯逻辑，不碰页面/网络）。
///
/// 对端协议（见 `agent/clipboard_sync.py`）：
/// - 上行：`{p:"clip", dir:"up", text}` —— 本机 → 被控端；
/// - 下行：`{p:"clip", dir:"down", text}` —— 被控端 → 本机；
/// - 开关：`{p:"clip.sync", enable}`。
///
/// 设计要点（抖动是这类功能的主要 bug 来源）：
/// 1. [lastText] 记「本机已知值」，两端都往里写：下行写入后写、上行成功后也写
///    （[markUploaded]）。这样「本机复制 → 上行 → 被控端改自己剪贴板 → 推回同值」
///    这条回环在第一步就被 [applyRemote] 判成 [ClipboardApplyResult.skippedSame]，
///    不会把用户的剪贴板反着覆盖回去；
/// 2. 超长不截断，交给调用方提示；
/// 3. 平台 API 的异常一律吞掉：剪贴板在无窗口/沙盒/受限 Electron 环境里
///    抛 PlatformException 是常态，不能因此崩掉整个远控页面。
///
/// 平台读写可注入（默认走 [Clipboard]），单测因此不需要真实剪贴板。
class ClipboardSync {
  ClipboardSync({
    Future<String?> Function()? readClipboard,
    Future<void> Function(String text)? writeClipboard,
    int maxChars = 200000,
    this.enabled = true,
  })  : _readClipboard = readClipboard ?? _platformRead,
        _writeClipboard = writeClipboard ?? _platformWrite,
        // 私有字段不能写成 `this._maxChars`（命名参数不允许下划线开头）。
        // ignore: prefer_initializing_formals
        _maxChars = maxChars;

  /// 平台读实现；测试注入假实现，避免依赖 channel 与测试宿主环境。
  final Future<String?> Function() _readClipboard;

  /// 平台写实现；同上。
  final Future<void> Function(String text) _writeClipboard;

  /// 单次同步的字符上限。默认 200000 与 Agent 侧 256KB 的意图一致（UTF-8 下
  /// 中文 3 字节/字，取 200k 字符保证大多数文本不会先被对端丢掉）。
  final int _maxChars;

  /// 同步开关：`{p:"clip.sync", enable}` 落到这里，关掉后两个方向都不动作。
  bool enabled;

  /// 本机已知文本：下行写入值，或最近一次成功上行的值。
  String? _lastText;

  /// 最近一次跳过的原因，仅由 [applyRemote] 写入。
  ///
  /// [takeLocalForUpload] 是轮询路径，失败/无事发生时不改这里——
  /// 否则每 800ms 就会把 UI 提示刷成噪音。
  ClipboardApplyResult? _lastSkip;

  /// 最近一次已知文本（调试与测试用）。
  String? get lastText => _lastText;

  /// 被跳过的最近一次原因（UI 提示用，可能是 null）。
  ClipboardApplyResult? get lastSkip => _lastSkip;

  /// 被控端 → 本机：把下游文本写进系统剪贴板。
  ///
  /// 返回值语义见 [ClipboardApplyResult]。写平台剪贴板抛异常时吞掉并返回
  /// [ClipboardApplyResult.skippedEmpty]（枚举没有专门的 failed 值，调用方
  /// 只要判断「不是 applied」即为未成功），同时**不**更新 [lastText]，
  /// 免得下次同值被判成 skippedSame 而永远写不进去。
  Future<ClipboardApplyResult> applyRemote(String text) async {
    if (!enabled) return _skip(ClipboardApplyResult.skippedOff);
    if (text.trim().isEmpty) return _skip(ClipboardApplyResult.skippedEmpty);
    if (text.length > _maxChars) return _skip(ClipboardApplyResult.skippedTooLong);
    if (text == _lastText) return _skip(ClipboardApplyResult.skippedSame);

    try {
      await _writeClipboard(text);
    } catch (_) {
      // 平台剪贴板在无窗口/受限环境会抛 PlatformException，页面不能因此崩。
      return _skip(ClipboardApplyResult.skippedEmpty);
    }
    _lastText = text;
    _lastSkip = null;
    return ClipboardApplyResult.applied;
  }

  /// 本机 → 被控端：取出待上行文本。
  ///
  /// 关闭、无文本、全空白、超过 `maxChars`、与 [lastText] 相同（含刚下行写入的
  /// 内容，否则会把被控端推来的文本再推回去）都返回 null。读剪贴板抛异常时
  /// 同样返回 null，不打断轮询。
  ///
  /// 成功取出时会顺手把值记进 [lastText]：调用方即使忘记调 [markUploaded]，
  /// 紧随其后的下游回声也会被 [applyRemote] 判成 skippedSame。
  Future<String?> takeLocalForUpload() async {
    if (!enabled) return null;

    String? text;
    try {
      text = await _readClipboard();
    } catch (_) {
      return null;
    }
    if (text == null || text.trim().isEmpty) return null;
    if (text.length > _maxChars) return null;
    if (text == _lastText) return null;

    _lastText = text;
    return text;
  }

  /// 上行成功后登记，用于抑制被控端回声。
  ///
  /// 空串不登记：那会把 [lastText] 擦成空值，导致原本的去重基线失效。
  void markUploaded(String text) {
    if (text.isEmpty) return;
    _lastText = text;
  }

  ClipboardApplyResult _skip(ClipboardApplyResult reason) {
    _lastSkip = reason;
    return reason;
  }
}

/// 默认读：平台剪贴板纯文本；无内容时 [ClipboardData.text] 为 null。
Future<String?> _platformRead() async {
  final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
  return data?.text;
}

/// 默认写：整段覆盖系统剪贴板（[Clipboard.setData] 本身就是覆盖语义）。
Future<void> _platformWrite(String text) =>
    Clipboard.setData(ClipboardData(text: text));
