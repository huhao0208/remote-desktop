import 'package:material_ui/material_ui.dart';

/// 全端统一「浅色官方风」：浅灰蓝底 + 纯白卡片 + 蓝色主色。
/// 远控画面本身仍深色，单独用 [AppColors.videoBg] 那组常量，不混用。
class AppColors {
  const AppColors._();

  // 底色与面
  static const Color bg = Color(0xFFF3F5F7);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceAlt = Color(0xFFF7F9FB);
  static const Color elevated = Color(0xFFFFFFFF);

  // 分隔与边框
  static const Color border = Color(0xFFDFE3E8);
  static const Color borderStrong = Color(0xFFD8DDE3);

  // 文字灰阶
  static const Color text = Color(0xFF1A1A1C);
  static const Color muted = Color(0xFF6B7078);
  static const Color faint = Color(0xFFA8AEB5);

  // 主色与语义色
  static const Color accent = Color(0xFF3478F6);
  static const Color accentHover = Color(0xFF2E6BE0);
  static const Color accentDim = Color(0xFFE8F0FE);
  static const Color online = Color(0xFF34C759);
  static const Color offline = Color(0xFFBFC3C8);
  static const Color danger = Color(0xFFFF3B30);
  static const Color warn = Color(0xFFFF9500);
  static const Color info = Color(0xFF3478F6);

  /// 遮罩
  static const Color backdrop = Color(0x73000000);

  // 远控视频区（保持深色，避免亮底影响判断画面边界）
  static const Color videoBg = Color(0xFF0B0D10);
  static const Color videoChrome = Color(0xE61A1D23);
  static const Color videoChromeBorder = Color(0x33FFFFFF);
  static const Color videoText = Color(0xFFF2F4F7);
  static const Color videoMuted = Color(0xFF9AA3AE);
}

/// 8dp 栅格
class AppSpace {
  const AppSpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;
}

class AppRadius {
  const AppRadius._();

  static const double sm = 10;
  static const double md = 14;
  static const double lg = 18;
  static const double pill = 999;
}

class AppShadows {
  const AppShadows._();

  /// 浅色卡片只给极轻的投影，靠底色对比分层，不用重阴影
  static const List<BoxShadow> card = <BoxShadow>[
    BoxShadow(color: Color(0x0D101828), blurRadius: 10, offset: Offset(0, 2)),
  ];

  static const List<BoxShadow> floating = <BoxShadow>[
    BoxShadow(color: Color(0x1A101828), blurRadius: 24, offset: Offset(0, 8)),
  ];
}

/// 响应式断点
class Breakpoints {
  const Breakpoints._();

  /// 桌面宽屏：主从两栏
  static const double wide = 900;

  /// 平板：列表可加宽边距
  static const double medium = 600;

  static bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= wide;

  /// 平板/小窗：够宽就用桌面布局，但比 [wide] 松
  static bool isMedium(BuildContext context) => MediaQuery.sizeOf(context).width >= medium;
}

/// 文字层级：大标题 28/700，卡片标题 16/500，正文 14，辅助 12
class AppText {
  const AppText._();

  static const TextTheme text = TextTheme(
    displaySmall: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: AppColors.text, height: 1.2),
    titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.text),
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: AppColors.text),
    bodyMedium: TextStyle(fontSize: 14, color: AppColors.text, height: 1.5),
    bodySmall: TextStyle(fontSize: 12, color: AppColors.muted, height: 1.4),
    labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.text),
    labelSmall: TextStyle(fontSize: 11, color: AppColors.muted),
  );
}

/// [fontFamily] 只给截图测试用，正常运行交给系统默认字体。
ThemeData buildAppTheme({String? fontFamily}) {
  // 组件级 textStyle 不会自动继承 ThemeData.fontFamily，测试字体只有单族，
  // 这里统一补齐，避免截图里按钮/链接回退成方块。
  TextStyle? f(TextStyle? s) => s?.copyWith(
        fontFamily: fontFamily,
        fontFamilyFallback: <String>[?fontFamily],
      );
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.light,
  ).copyWith(
    primary: AppColors.accent,
    onPrimary: Colors.white,
    surface: AppColors.surface,
    onSurface: AppColors.text,
    outline: AppColors.border,
    error: AppColors.danger,
  );

  return ThemeData(
    useMaterial3: true,
    fontFamily: fontFamily,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    canvasColor: AppColors.bg,
    dividerColor: AppColors.border,
    textTheme: fontFamily == null
        ? AppText.text
        : AppText.text.apply(fontFamily: fontFamily, fontFamilyFallback: <String>[fontFamily]),
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      foregroundColor: AppColors.text,
      titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.text),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      hintStyle: const TextStyle(fontSize: 14, color: AppColors.faint),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm), borderSide: const BorderSide(color: AppColors.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm), borderSide: const BorderSide(color: AppColors.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm), borderSide: const BorderSide(color: AppColors.accent, width: 1.4)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm), borderSide: const BorderSide(color: AppColors.danger)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: AppColors.border,
        disabledForegroundColor: AppColors.faint,
        elevation: 0,
        minimumSize: const Size(0, 46),
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.pill)),
        textStyle: f(const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
        textStyle: f(const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: AppColors.muted),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
      titleTextStyle: f(const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.text)),
      contentTextStyle: f(const TextStyle(fontSize: 14, color: AppColors.muted, height: 1.5)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg))),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: const Color(0xFF2B2D30),
      contentTextStyle: f(const TextStyle(fontSize: 13, color: Colors.white)),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.accent),
    dividerTheme: const DividerThemeData(color: AppColors.border, thickness: 1, space: 1),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
      textStyle: const TextStyle(fontSize: 14, color: AppColors.text),
    ),
  );
}