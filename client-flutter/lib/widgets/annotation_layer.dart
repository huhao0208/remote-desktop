import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../core/view_mode.dart';

/// 批注叠加层：把 [AnnotationBoard] 里的归一化笔画画到画面上。
///
/// 关键设计：笔画存的是**归一化坐标**（0..1），所以窗口缩放、全屏切换、
/// 分辨率变化都不需要重新换算——直接乘当前 viewport 即可。
///
/// 这一层必须由调用方用 [IgnorePointer] 包住（非批注态）或让画面层
/// 让出手势（批注态），否则会抢走远控页最外层 Listener 的指针事件。
class AnnotationLayer extends StatelessWidget {
  const AnnotationLayer({
    required this.board,
    required this.revision,
    this.opacity = 1.0,
    super.key,
  });

  final AnnotationBoard board;

  /// `board.revision`。传进来是为了让 `shouldRepaint` 有得比较——
  /// 可变对象不会触发重建，只能靠这个整数当版本号。
  final int revision;

  /// 整层透明度。批注偶尔会挡住画面细节，允许调淡。
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Opacity(
        opacity: opacity,
        child: CustomPaint(
          painter: _AnnotationPainter(board: board, revision: revision),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _AnnotationPainter extends CustomPainter {
  _AnnotationPainter({required this.board, required this.revision});

  final AnnotationBoard board;
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || board.isEmpty) return;
    final List<AnnotationStroke> strokes = board.strokes;
    for (final AnnotationStroke stroke in strokes) {
      _drawStroke(canvas, size, stroke);
    }
    // 正在画的那一笔：`end()` 之前它还不在 strokes 里
    final List<Offset> active = board.activeNormalizedPoints;
    if (active.length > 1) {
      _drawPoints(
        canvas,
        size,
        active,
        color: Color(strokes.isEmpty ? 0xFFFF3B30 : strokes.last.colorArgb),
        width: strokes.isEmpty ? 3.0 : strokes.last.width,
      );
    }
  }

  void _drawStroke(Canvas canvas, Size size, AnnotationStroke stroke) {
    if (stroke.points.length < 2) return;
    _drawPoints(
      canvas,
      size,
      stroke.points,
      color: Color(stroke.colorArgb),
      width: stroke.width,
    );
  }

  void _drawPoints(
    Canvas canvas,
    Size size,
    List<Offset> points, {
    required Color color,
    required double width,
  }) {
    final Path path = Path();
    final Offset first = Offset(points.first.dx * size.width, points.first.dy * size.height);
    path.moveTo(first.dx, first.dy);
    for (int i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx * size.width, points[i].dy * size.height);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_AnnotationPainter oldDelegate) =>
      oldDelegate.revision != revision || oldDelegate.board != board;
}

/// 批注态下显示在画面上的小工具：颜色与撤销/清空。
///
/// 单独拆出来是因为它需要接收点击（不能塞进 [AnnotationLayer] 的
/// IgnorePointer 里），而绘制层和交互层分开后各管一件事。
class AnnotationBar extends StatelessWidget {
  const AnnotationBar({
    required this.color,
    required this.onColor,
    required this.onUndo,
    required this.onClear,
    required this.canUndo,
    required this.strokeCount,
    super.key,
  });

  final Color color;
  final ValueChanged<Color> onColor;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final bool canUndo;
  final int strokeCount;

  /// 官方没给具体配色，选四个在深浅背景上都能看清的高饱和色。
  static const List<Color> palette = <Color>[
    Color(0xFFFF3B30),
    Color(0xFFFFCC00),
    Color(0xFF34C759),
    Color(0xFF3478F6),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final Color c in palette) ...<Widget>[
          _dot(c),
          const SizedBox(width: 4),
        ],
        const SizedBox(width: 2),
        _action(
          icon: Icons.undo,
          tip: canUndo ? '撤销上一笔（共 $strokeCount 笔）' : '还没有可撤销的笔画',
          enabled: canUndo,
          onTap: onUndo,
        ),
        _action(
          icon: Icons.delete_outline,
          tip: strokeCount == 0 ? '还没有批注' : '清空全部批注（$strokeCount 笔）',
          enabled: strokeCount > 0,
          onTap: onClear,
        ),
      ],
    );
  }

  Widget _dot(Color c) {
    final bool active = c.toARGB32() == color.toARGB32();
    return Tooltip(
      message: '画笔颜色',
      child: InkResponse(
        onTap: () => onColor(c),
        radius: 14,
        child: Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: active ? AppColors.videoText : Colors.transparent,
              width: 2,
            ),
          ),
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String tip,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tip,
      child: InkResponse(
        onTap: enabled ? onTap : null,
        radius: 16,
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(
            icon,
            size: 17,
            color: enabled ? AppColors.videoText : AppColors.videoMuted.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}
