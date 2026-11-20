import 'package:material_ui/material_ui.dart';

/// 配色对齐现有 `client-desktop` / `srv2/control.html`。
class AppColors {
  AppColors._();

  static const Color bg = Color(0xFF0D1117);
  static const Color surface = Color(0xFF161B22);
  static const Color surfaceAlt = Color(0xFF1F2630);
  static const Color border = Color(0xFF30363D);
  static const Color accent = Color(0xFF2EA043);
  static const Color accentDim = Color(0xFF238636);
  static const Color danger = Color(0xFFDA3633);
  static const Color warn = Color(0xFFD29922);
  static const Color text = Color(0xFFE6EDF3);
  static const Color muted = Color(0xFF8B949E);
}

ThemeData buildAppTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.accent,
    onPrimary: Colors.white,
    surface: AppColors.bg,
    onSurface: AppColors.text,
    error: AppColors.danger,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    dividerColor: AppColors.border,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      foregroundColor: AppColors.text,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      hintStyle: const TextStyle(color: AppColors.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: AppColors.accentDim.withValues(alpha: 0.4),
        minimumSize: const Size(0, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.accent),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surfaceAlt,
      contentTextStyle: TextStyle(color: AppColors.text),
      behavior: SnackBarBehavior.floating,
    ),
  );
}