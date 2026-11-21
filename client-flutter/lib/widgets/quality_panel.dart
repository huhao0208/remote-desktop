import 'package:material_ui/material_ui.dart';

import '../core/app_config.dart';
import '../core/theme.dart';

/// 画质下拉面板（官方 `Control.Menu.Quality` 的六个档位 + 细项）。
///
/// 交互对齐官方 B2.2：
/// - 档位/分辨率/帧率切换**即时生效**，没有「确定」；
/// - 分隔线把「档位」「分辨率+帧率」「码率」分三段；
/// - 底部常驻一行「最终参数」，让用户一眼看到实际值（避免以为改了没生效）。
Future<void> showQualityPanel(
  BuildContext context, {
  required StreamPrefs prefs,
  int agentMaxFps = 60,
  required ValueChanged<StreamPrefs> onChanged,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '画质设置',
    // 不变暗：这是下拉面板不是模态对话框，画面要保持可见才好判断画质
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (BuildContext ctx, Animation<double> a, Animation<double> b) =>
        const SizedBox.shrink(),
    transitionBuilder:
        (BuildContext ctx, Animation<double> anim, Animation<double> b, Widget child) {
      return FadeTransition(
        opacity: anim,
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 52, right: 10, bottom: 56),
            child: _QualityPanel(
              initial: prefs,
              agentMaxFps: agentMaxFps,
              onChanged: onChanged,
            ),
          ),
        ),
      );
    },
  );
}

class _QualityPanel extends StatefulWidget {
  const _QualityPanel({
    required this.initial,
    required this.agentMaxFps,
    required this.onChanged,
  });

  final StreamPrefs initial;
  final int agentMaxFps;
  final ValueChanged<StreamPrefs> onChanged;

  @override
  State<_QualityPanel> createState() => _QualityPanelState();
}

class _QualityPanelState extends State<_QualityPanel> {
  late StreamPrefs _prefs = widget.initial;

  /// 「跟随当前显示屏」的像素宽：逻辑宽 × DPR，钳到 H.264 友好的范围。
  int get _localWidth {
    final MediaQueryData mq = MediaQuery.of(context);
    return (mq.size.width * mq.devicePixelRatio).round().clamp(640, 3840);
  }

  void _apply(StreamPrefs next) {
    setState(() => _prefs = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 320,
        decoration: BoxDecoration(
          color: AppColors.videoChrome,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.videoChromeBorder),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 26,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
              child: Row(
                children: <Widget>[
                  const Text('画质',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.videoText)),
                  const Spacer(),
                  InkWell(
                    onTap: () => Navigator.of(context).maybePop(),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close, size: 16, color: AppColors.videoMuted),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final QualityPreset p in AppConfig.qualityPresets) _presetTile(p),
                    _divider(),
                    _resolutionRow(),
                    _fpsRow(),
                    _divider(),
                    _bitrateSection(),
                  ],
                ),
              ),
            ),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _presetTile(QualityPreset p) {
    final bool on = _prefs.preset.key == p.key;
    return InkWell(
      onTap: () => _apply(_prefs.copyWith(preset: p)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: <Widget>[
            Icon(
              on ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 15,
              color: on ? AppColors.accent : AppColors.videoMuted,
            ),
            const SizedBox(width: 8),
            Text(
              p.label,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.2,
                color: on ? AppColors.videoText : AppColors.videoMuted,
                fontWeight: on ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(width: 6),
            Text(p.hint, style: const TextStyle(fontSize: 10.5, color: AppColors.videoMuted)),
            const Spacer(),
            if (p.bitrate > 0)
              Text(
                '${(p.bitrate / 1000).round()}M',
                style: const TextStyle(fontSize: 10.5, color: AppColors.videoMuted),
              ),
          ],
        ),
      ),
    );
  }

  Widget _divider() => Container(
        height: 1,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: AppColors.videoChromeBorder,
      );

  Widget _resolutionRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: <Widget>[
          const Text('分辨率', style: TextStyle(fontSize: 12, color: AppColors.videoMuted)),
          const Spacer(),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _prefs.resolutionKey,
              isDense: true,
              dropdownColor: AppColors.videoChrome,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              style: const TextStyle(fontSize: 12, color: AppColors.videoText),
              icon: const Icon(Icons.expand_more, size: 15, color: AppColors.videoMuted),
              items: AppConfig.resolutions
                  .map((ResolutionOption r) => DropdownMenuItem<String>(
                        value: r.key,
                        child: Text(
                          r.key == 'follow_local' && r.width == 0
                              ? '跟随当前显示屏'
                              : r.label,
                          style: const TextStyle(fontSize: 12, color: AppColors.videoText),
                        ),
                      ))
                  .toList(),
              onChanged: (String? key) {
                if (key == null) return;
                _apply(_prefs.copyWith(
                  resolutionKey: key,
                  // 选中「跟随当前显示屏」时把当次算出的宽度存下来，
                  // 换机器/换窗口尺寸后仍按新值刷新（见 _localWidth）
                  resolutionWidth: key == 'follow_local' ? _localWidth : _prefs.resolutionWidth,
                ));
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _fpsRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Row(
        children: <Widget>[
          const Text('帧率', style: TextStyle(fontSize: 12, color: AppColors.videoMuted)),
          const SizedBox(width: 10),
          for (final int f in AppConfig.fpsOptions)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: _FpsChip(
                  fps: f,
                  selected: _prefs.fps == f,
                  // 探测值只用来提示，不禁用：探测本身有误差，误禁比误开更烦人
                  beyondCapability: f > widget.agentMaxFps,
                  onTap: () => _apply(_prefs.copyWith(fps: f)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bitrateSection() {
    final bool on = _prefs.customBitrate;
    final int shown = _prefs.bitrate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          onTap: () => _apply(
            _prefs.copyWith(
              customBitrate: !on,
              // 首次打开把当前生效值写进滑块，避免从 0 开始拖
              bitrateOverride: !on && _prefs.bitrateOverride == 0 ? shown : _prefs.bitrateOverride,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: <Widget>[
                Icon(on ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 16, color: on ? AppColors.accent : AppColors.videoMuted),
                const SizedBox(width: 8),
                const Text('启用自定义码率',
                    style: TextStyle(fontSize: 12, color: AppColors.videoText)),
                const Spacer(),
                Text('$shown kbps',
                    style: const TextStyle(fontSize: 11, color: AppColors.videoMuted)),
              ],
            ),
          ),
        ),
        if (on)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: AppColors.accent,
                inactiveTrackColor: AppColors.videoChromeBorder,
                thumbColor: AppColors.accent,
              ),
              child: Slider(
                value: shown
                    .clamp(AppConfig.minCustomBitrate, AppConfig.maxCustomBitrate)
                    .toDouble(),
                min: AppConfig.minCustomBitrate.toDouble(),
                max: AppConfig.maxCustomBitrate.toDouble(),
                divisions: 49,
                onChanged: (double v) => _apply(_prefs.copyWith(
                  bitrateOverride: (v / 1000).round() * 1000,
                )),
              ),
            ),
          ),
      ],
    );
  }

  Widget _footer() {
    final String w = _prefs.width <= 0 ? '源分辨率' : '${_prefs.width}P';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.videoChromeBorder)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '$w · ${_prefs.fps}fps · ${_prefs.bitrate}kbps',
              style: const TextStyle(fontSize: 10.5, color: AppColors.videoMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            style: TextButton.styleFrom(
              minimumSize: const Size(56, 28),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('完成', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// 帧率小方块：选中实底，超出被控端探测能力时用警示色（仍可选）。
class _FpsChip extends StatelessWidget {
  const _FpsChip({
    required this.fps,
    required this.selected,
    required this.beyondCapability,
    required this.onTap,
  });

  final int fps;
  final bool selected;
  final bool beyondCapability;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color fg = selected
        ? Colors.white
        : (beyondCapability ? AppColors.warn : AppColors.videoMuted);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.videoBg,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.videoChromeBorder,
          ),
        ),
        child: Text(
          '$fps',
          style: TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}
