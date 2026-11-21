import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/view_mode.dart';

/// 内容点在某变换下落到屏幕的哪里（`focal = offset + p * scale` 的正面解）。
Offset _toScreen(ViewTransform t, Offset content) => t.offset + content * t.scale;

/// 屏幕点对应哪个内容点（逆解），用来验「锚点不动」。
Offset _toContent(ViewTransform t, Offset screen) => (screen - t.offset) / t.scale;

void main() {
  group('三态语义', () {
    test('操控态不拦截输入，观看与批注态拦截', () {
      expect(ViewState.control.interceptsInput, isFalse);
      expect(ViewState.view.interceptsInput, isTrue);
      expect(ViewState.annotation.interceptsInput, isTrue);
    });

    test('label 依次为 操控 / 观看 / 批注', () {
      expect(ViewState.control.label, '操控');
      expect(ViewState.view.label, '观看');
      expect(ViewState.annotation.label, '批注');
    });

    test('canAnnotate：操控态关闭，观看与批注态开启', () {
      const ViewModeState control = ViewModeState();
      expect(control.state, ViewState.control);
      expect(control.canAnnotate, isFalse);
      expect(control.copyWith(state: ViewState.view).canAnnotate, isTrue);
      expect(control.copyWith(state: ViewState.annotation).canAnnotate, isTrue);
    });

    test('默认状态：操控、工具栏可见、单位变换', () {
      const ViewModeState s = ViewModeState();
      expect(s.toolbarVisible, isTrue);
      expect(s.transform.scale, 1.0);
      expect(s.transform.offset, Offset.zero);
      expect(s.transform.isIdentity, isTrue);
    });

    test('copyWith 只改传入的字段', () {
      const ViewModeState s = ViewModeState(state: ViewState.view, toolbarVisible: false);
      final ViewModeState onlyToolbar = s.copyWith(toolbarVisible: true);
      expect(onlyToolbar.state, ViewState.view);
      expect(onlyToolbar.toolbarVisible, isTrue);
      expect(onlyToolbar.transform.isIdentity, isTrue);

      final ViewModeState onlyTransform =
          s.copyWith(transform: const ViewTransform(scale: 2.0));
      expect(onlyTransform.state, ViewState.view);
      expect(onlyTransform.toolbarVisible, isFalse);
      expect(onlyTransform.transform.scale, 2.0);
    });
  });

  group('缩放 zoomAt', () {
    const Size viewport = Size(800, 600);

    test('1.0 起步放大后 scale 生效，且 isIdentity 为 false', () {
      final ViewTransform t = const ViewTransform()
          .zoomAt(focal: const Offset(400, 300), factor: 2.0, viewport: viewport);
      expect(t.scale, 2.0);
      expect(t.isIdentity, isFalse);
    });

    test('以 focal 为锚点：缩放前后该内容点的屏幕位置不变', () {
      const Offset focal = Offset(400, 300);
      const ViewTransform base = ViewTransform();
      final Offset content = _toContent(base, focal);
      final ViewTransform zoomed = base.zoomAt(focal: focal, factor: 2.0, viewport: viewport);

      final Offset after = _toScreen(zoomed, content);
      expect(after.dx, closeTo(focal.dx, 1e-9));
      expect(after.dy, closeTo(focal.dy, 1e-9));
    });

    test('已有平移时锚点依然不动（放大 1.5 倍）', () {
      const Offset focal = Offset(400, 300);
      const ViewTransform base = ViewTransform(scale: 2.0, offset: Offset(-300, -200));
      final Offset content = _toContent(base, focal);
      final ViewTransform zoomed = base.zoomAt(focal: focal, factor: 1.5, viewport: viewport);

      expect(zoomed.scale, 3.0);
      final Offset after = _toScreen(zoomed, content);
      expect(after.dx, closeTo(focal.dx, 1e-9));
      expect(after.dy, closeTo(focal.dy, 1e-9));
    });

    test('放大夹到 maxScale=4.0', () {
      final ViewTransform t = const ViewTransform()
          .zoomAt(focal: const Offset(400, 300), factor: 100.0, viewport: viewport);
      expect(t.scale, ViewTransform.maxScale);
    });

    test('缩小夹到 minScale=0.5', () {
      final ViewTransform t = const ViewTransform()
          .zoomAt(focal: const Offset(400, 300), factor: 0.001, viewport: viewport);
      expect(t.scale, ViewTransform.minScale);
    });

    test('连滚多档时逐次夹取，始终不超过上下限', () {
      ViewTransform t = const ViewTransform();
      for (int i = 0; i < 20; i++) {
        t = t.zoomAt(focal: const Offset(200, 100), factor: 1.3, viewport: viewport);
        expect(t.scale, lessThanOrEqualTo(ViewTransform.maxScale));
      }
      for (int i = 0; i < 30; i++) {
        t = t.zoomAt(focal: const Offset(200, 100), factor: 0.8, viewport: viewport);
        expect(t.scale, greaterThanOrEqualTo(ViewTransform.minScale));
      }
    });

    test('缩回 1.0 以下时 offset 归零（画面不会被留在偏移位置）', () {
      const ViewTransform zoomed = ViewTransform(scale: 4.0, offset: Offset(-100, -100));
      final ViewTransform t =
          zoomed.zoomAt(focal: const Offset(800, 600), factor: 0.1, viewport: viewport);
      expect(t.scale, ViewTransform.minScale);
      expect(t.offset, Offset.zero);
    });

    test('factor 为 0 / 负数 / NaN 时原样返回，不产生非法变换', () {
      const ViewTransform base = ViewTransform(scale: 2.0, offset: Offset(-10, -20));
      for (final double f in <double>[0.0, -1.0, double.nan, double.infinity]) {
        final ViewTransform t = base.zoomAt(focal: Offset.zero, factor: f, viewport: viewport);
        expect(t.scale, 2.0, reason: 'factor=$f');
        expect(t.offset, const Offset(-10, -20), reason: 'factor=$f');
      }
    });
  });

  group('平移 pan', () {
    const Size viewport = Size(800, 600);

    test('scale<=1 时 offset 被强制归零（没有可平移余量）', () {
      for (final double s in <double>[1.0, 0.8, 0.5]) {
        final ViewTransform t =
            ViewTransform(scale: s).pan(const Offset(120, 80), viewport);
        expect(t.offset, Offset.zero, reason: 'scale=$s');
        expect(t.scale, s);
      }
    });

    test('scale>1 时在范围内正常平移', () {
      final ViewTransform t =
          const ViewTransform(scale: 2.0).pan(const Offset(-100, -50), viewport);
      expect(t.offset, const Offset(-100, -50));
      expect(t.scale, 2.0);
    });

    test('scale>1 时向右下拖到顶就夹在 0（画面左上不能离开视口左上）', () {
      final ViewTransform t =
          const ViewTransform(scale: 2.0).pan(const Offset(1000, 1000), viewport);
      expect(t.offset, Offset.zero);
    });

    test('scale>1 时向左上拖到顶夹在 [-viewport*(scale-1), 0]', () {
      final ViewTransform t =
          const ViewTransform(scale: 2.0).pan(const Offset(-5000, -5000), viewport);
      expect(t.offset.dx, closeTo(-800, 1e-9));
      expect(t.offset.dy, closeTo(-600, 1e-9));
    });

    test('先越过边界再往回拖，能按当前位置继续移动', () {
      final ViewTransform atEdge =
          const ViewTransform(scale: 2.0).pan(const Offset(-5000, -5000), viewport);
      final ViewTransform back = atEdge.pan(const Offset(100, 100), viewport);
      expect(back.offset, const Offset(-700, -500));
    });
  });

  group('reset 与 normalizedOffset', () {
    const Size viewport = Size(800, 600);

    test('reset 回到 1.0 / Offset.zero', () {
      const ViewTransform t = ViewTransform(scale: 3.5, offset: Offset(-420, -310));
      expect(t.reset().scale, 1.0);
      expect(t.reset().offset, Offset.zero);
      expect(t.reset().isIdentity, isTrue);
    });

    test('scale<=1 时 normalizedOffset 为 0', () {
      for (final double s in <double>[1.0, 0.7]) {
        final ViewTransform t = ViewTransform(scale: s, offset: const Offset(-10, -10));
        expect(t.normalizedOffset(viewport), Offset.zero, reason: 'scale=$s');
      }
    });

    test('scale>1 时按「最大可平移量」取比例（拖到边界为 1.0）', () {
      const ViewTransform edge = ViewTransform(scale: 3.0, offset: Offset(-800, -600));
      expect(edge.normalizedOffset(viewport).dx, closeTo(0.5, 1e-9));
      expect(edge.normalizedOffset(viewport).dy, closeTo(0.5, 1e-9));

      const ViewTransform far = ViewTransform(scale: 2.0, offset: Offset(-800, -600));
      expect(far.normalizedOffset(viewport).dx, closeTo(1.0, 1e-9));
      expect(far.normalizedOffset(viewport).dy, closeTo(1.0, 1e-9));

      const ViewTransform centered = ViewTransform(scale: 2.0, offset: Offset(-400, -300));
      expect(centered.normalizedOffset(viewport).dx, closeTo(0.5, 1e-9));
      expect(centered.normalizedOffset(viewport).dy, closeTo(0.5, 1e-9));
    });

    test('viewport 为 0 时 normalizedOffset 为 0，不产生 NaN', () {
      const ViewTransform t = ViewTransform(scale: 2.0, offset: Offset(-100, -100));
      expect(t.normalizedOffset(Size.zero), Offset.zero);
      expect(t.normalizedOffset(const Size(0, 600)), Offset.zero);
      expect(t.normalizedOffset(const Size(800, 0)), Offset.zero);
    });
  });

  group('批注笔画 AnnotationBoard', () {
    test('begin 起笔成功，笔画里只有起点', () {
      final AnnotationBoard board = AnnotationBoard();
      expect(board.isEmpty, isTrue);
      expect(board.begin(const Offset(0.5, 0.5)), isTrue);
      expect(board.isEmpty, isFalse);
      expect(board.strokes.length, 1);
      expect(board.strokes.last.points.length, 1);
      expect(board.strokes.last.points.single, const Offset(0.5, 0.5));
    });

    test('begin 到达 maxStrokes=200 上限后返回 false，且不再追加', () {
      final AnnotationBoard board = AnnotationBoard();
      for (int i = 0; i < AnnotationBoard.maxStrokes; i++) {
        expect(board.begin(const Offset(0.1, 0.1)), isTrue);
        expect(board.extend(const Offset(0.2, 0.2)), isTrue);
        board.end();
      }
      expect(board.strokes.length, AnnotationBoard.maxStrokes);

      expect(board.begin(const Offset(0.5, 0.5)), isFalse);
      expect(board.strokes.length, AnnotationBoard.maxStrokes);
    });

    test('extend 在没有进行中的笔画时返回 false', () {
      final AnnotationBoard board = AnnotationBoard();
      expect(board.extend(const Offset(0.3, 0.3)), isFalse);
      expect(board.isEmpty, isTrue);
    });

    test('extend 抖动过滤：距离 0.001 的点不追加', () {
      final AnnotationBoard board = AnnotationBoard();
      board.begin(const Offset(0.4, 0.4));
      expect(board.extend(const Offset(0.401, 0.4)), isFalse, reason: '距离 0.001 < 0.002');
      expect(board.strokes.last.points.length, 1);
      expect(board.strokes.last.points.last, const Offset(0.4, 0.4));
    });

    test('extend 距离足够时正常追加', () {
      final AnnotationBoard board = AnnotationBoard();
      board.begin(const Offset(0.1, 0.1));
      expect(board.extend(const Offset(0.2, 0.1)), isTrue);
      expect(board.strokes.last.points.length, 2);
      expect(board.strokes.last.points.last, const Offset(0.2, 0.1));
    });

    test('extend 超过 maxPointsPerStroke=2000 后忽略后续点', () {
      final AnnotationBoard board = AnnotationBoard();
      board.begin(const Offset(0.0, 0.0));
      for (int i = 1; i <= AnnotationBoard.maxPointsPerStroke + 10; i++) {
        // 在 0..1 范围内来回折返，相邻点距离远大于抖动阈值。
        final Offset p = Offset((i ~/ 2 % 100) * 0.01, i.isEven ? 0.0 : 0.01);
        board.extend(p);
      }
      expect(board.strokes.last.points.length, AnnotationBoard.maxPointsPerStroke);
      expect(board.extend(const Offset(0.99, 0.99)), isFalse);
      expect(board.strokes.last.points.length, AnnotationBoard.maxPointsPerStroke);
    });

    test('end 丢弃只有 1 个点的笔画（单击不算一笔）', () {
      final AnnotationBoard board = AnnotationBoard();
      board.begin(const Offset(0.3, 0.3));
      board.end();
      expect(board.isEmpty, isTrue);
      expect(board.strokes, isEmpty);
    });

    test('end 保留 2 个点以上的笔画', () {
      final AnnotationBoard board = AnnotationBoard();
      board.begin(const Offset(0.1, 0.1));
      board.extend(const Offset(0.2, 0.2));
      board.end();
      expect(board.strokes.length, 1);
      expect(board.strokes.single.points.length, 2);
    });

    test('end 之后 extend 返回 false（没有进行中的笔画）', () {
      final AnnotationBoard board = AnnotationBoard();
      board.begin(const Offset(0.1, 0.1));
      board.extend(const Offset(0.2, 0.2));
      board.end();
      expect(board.extend(const Offset(0.5, 0.5)), isFalse);
    });

    test('undo 移除最后一笔，空画板上调用安全', () {
      final AnnotationBoard board = AnnotationBoard();
      board.undo();
      expect(board.isEmpty, isTrue);

      board.begin(const Offset(0.1, 0.1));
      board.extend(const Offset(0.2, 0.2));
      board.end();
      board.begin(const Offset(0.6, 0.6));
      board.extend(const Offset(0.7, 0.7));
      board.end();
      expect(board.strokes.length, 2);

      board.undo();
      expect(board.strokes.length, 1);
      expect(board.strokes.single.points.first, const Offset(0.1, 0.1));

      board.undo();
      expect(board.isEmpty, isTrue);
      board.undo();
      expect(board.isEmpty, isTrue);
    });

    test('clear 清空全部，空画板上调用安全', () {
      final AnnotationBoard board = AnnotationBoard();
      board.clear();
      expect(board.isEmpty, isTrue);

      board.begin(const Offset(0.1, 0.1));
      board.extend(const Offset(0.2, 0.2));
      board.end();
      board.clear();
      expect(board.isEmpty, isTrue);
      expect(board.extend(const Offset(0.9, 0.9)), isFalse, reason: '清空后没有进行中的笔画');
    });

    test('revision 在每次真实变更后 +1，且单调递增', () {
      final AnnotationBoard board = AnnotationBoard();
      final List<int> seen = <int>[board.revision];
      expect(board.revision, 0);

      board.begin(const Offset(0.1, 0.1));
      seen.add(board.revision);
      board.extend(const Offset(0.2, 0.2));
      seen.add(board.revision);
      board.end();
      seen.add(board.revision);
      board.undo();
      seen.add(board.revision);
      board.clear(); // 已空，无变更
      seen.add(board.revision);

      expect(seen, <int>[0, 1, 2, 3, 4, 4]);
      for (int i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
      }
    });

    test('end 丢弃短笔画时 revision 也要 +1（painter 需抹掉临时笔迹）', () {
      final AnnotationBoard board = AnnotationBoard();
      board.begin(const Offset(0.1, 0.1));
      final int before = board.revision;
      board.end();
      expect(board.isEmpty, isTrue);
      expect(board.revision, before + 1);
    });

    test('抖动过滤不追加点时 revision 不变', () {
      final AnnotationBoard board = AnnotationBoard();
      board.begin(const Offset(0.4, 0.4));
      final int before = board.revision;
      board.extend(const Offset(0.4005, 0.4));
      expect(board.revision, before);
    });

    test('strokes 是只读视图，外部改不动内部状态', () {
      final AnnotationBoard board = AnnotationBoard();
      board.begin(const Offset(0.1, 0.1));
      expect(() => board.strokes.clear(), throwsUnsupportedError);
      expect(board.strokes.length, 1);
    });
  });

  group('像素换算', () {
    const Size viewport = Size(200, 100);

    test('toPixels 按 viewport 缩放最后一笔', () {
      final AnnotationBoard board = AnnotationBoard();
      board.begin(const Offset(0.25, 0.5));
      board.extend(const Offset(0.75, 1.0));
      board.end();

      final List<Offset> pixels = board.toPixels(viewport);
      expect(pixels.length, 2);
      expect(pixels[0].dx, closeTo(50, 1e-9));
      expect(pixels[0].dy, closeTo(50, 1e-9));
      expect(pixels[1].dx, closeTo(150, 1e-9));
      expect(pixels[1].dy, closeTo(100, 1e-9));
    });

    test('toPixels 只取最后一笔', () {
      final AnnotationBoard board = AnnotationBoard();
      board.begin(const Offset(0.0, 0.0));
      board.extend(const Offset(0.5, 0.5));
      board.end();
      board.begin(const Offset(1.0, 1.0));
      board.extend(const Offset(0.0, 0.0));
      board.end();

      final List<Offset> pixels = board.toPixels(viewport);
      expect(pixels.first.dx, closeTo(200, 1e-9));
      expect(pixels.first.dy, closeTo(100, 1e-9));
    });

    test('空画板 toPixels 返回空列表', () {
      expect(AnnotationBoard().toPixels(viewport), isEmpty);
    });

    test('0 尺寸 viewport 返回空列表且不抛异常', () {
      final AnnotationBoard board = AnnotationBoard();
      board.begin(const Offset(0.5, 0.5));
      board.extend(const Offset(0.6, 0.6));
      board.end();
      expect(board.toPixels(Size.zero), isEmpty);
      expect(board.toPixels(const Size(0, 100)), isEmpty);
      expect(board.toPixels(const Size(100, 0)), isEmpty);
    });

    test('activeNormalizedPoints 返回最后一笔的归一化点', () {
      final AnnotationBoard board = AnnotationBoard();
      expect(board.activeNormalizedPoints, isEmpty);

      board.begin(const Offset(0.2, 0.3));
      board.extend(const Offset(0.4, 0.5));
      final List<Offset> points = board.activeNormalizedPoints;
      expect(points.length, 2);
      expect(points.first, const Offset(0.2, 0.3));
      expect(points.last, const Offset(0.4, 0.5));
    });
  });
}
