import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';

abstract final class AppTheme {
  static final dark = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: AppColors.scheme,
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.surface,
    iconTheme: const IconThemeData(color: AppColors.ivory),
    hintColor: AppColors.muted,
    focusColor: AppColors.lavender.withValues(alpha: 0.18),
    hoverColor: AppColors.lavender.withValues(alpha: 0.08),
    fontFamily: 'PlusJakartaSans',
    textTheme: const TextTheme(
      displayLarge: TextStyle(
          fontSize: 36,
          fontWeight: FontWeight.w600,
          height: 44 / 36,
          letterSpacing: -1.08),
      displayMedium: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w600,
          height: 36 / 28,
          letterSpacing: -0.7),
      displaySmall: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w600,
          height: 36 / 28,
          letterSpacing: -0.7),
      headlineLarge: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w600,
          height: 38 / 30,
          letterSpacing: -0.6),
      headlineMedium: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          height: 32 / 24,
          letterSpacing: -0.48),
      headlineSmall: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w500,
          height: 28 / 20,
          letterSpacing: -0.3),
      titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w500,
          height: 28 / 20,
          letterSpacing: -0.3),
      titleMedium: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          height: 24 / 17,
          letterSpacing: -0.17),
      titleSmall: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 18 / 14,
          letterSpacing: 0.28),
      bodyLarge: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          height: 26 / 16,
          letterSpacing: -0.08),
      bodyMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          height: 22 / 14,
          letterSpacing: 0),
      bodySmall: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          height: 18 / 12,
          letterSpacing: 0.12,
          color: AppColors.muted),
      labelLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 18 / 14,
          letterSpacing: 0.28),
      labelMedium: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          height: 16 / 12,
          letterSpacing: 0.36),
      labelSmall: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          height: 14 / 10,
          letterSpacing: 0.6),
    ),
    filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
            shape: const StadiumBorder(),
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14))),
    elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
      shape: const StadiumBorder(),
      minimumSize: const Size(48, 48),
      backgroundColor: AppColors.lavender,
      foregroundColor: AppColors.surface,
      shadowColor: AppColors.coreCyan.withValues(alpha: 0.08),
      elevation: 1,
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
      shape: const StadiumBorder(),
      minimumSize: const Size(48, 48),
      foregroundColor: AppColors.ivory,
      backgroundColor: AppColors.surfaceRaised.withValues(alpha: 0.6),
      side: BorderSide(color: AppColors.lavender.withValues(alpha: 0.25)),
    )),
    textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
            shape: const StadiumBorder(), minimumSize: const Size(48, 48))),
    iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
            foregroundColor: AppColors.lavender,
            minimumSize: const Size(48, 48))),
    cardTheme: CardThemeData(
      color: AppColors.surface.withValues(alpha: 0.8),
      surfaceTintColor: AppColors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: AppColors.lavender.withValues(alpha: 0.12)),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: AppColors.surfaceRaised.withValues(alpha: 0.9),
      hintStyle: const TextStyle(color: AppColors.muted),
      labelStyle: const TextStyle(color: AppColors.muted),
      border: _inputBorder(AppColors.lavender.withValues(alpha: 0.18)),
      enabledBorder: _inputBorder(AppColors.lavender.withValues(alpha: 0.18)),
      disabledBorder: _inputBorder(AppColors.scheme.outlineVariant),
      focusedBorder: _inputBorder(AppColors.lavender),
      errorBorder: _inputBorder(AppColors.error),
      focusedErrorBorder: _inputBorder(AppColors.error),
    ),
    appBarTheme: const AppBarThemeData(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.ivory,
      surfaceTintColor: AppColors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: AppColors.background,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppColors.background,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: AppColors.ivory,
      unselectedLabelColor: AppColors.muted,
      dividerColor: AppColors.transparent,
      indicator: ShapeDecoration(
        color: AppColors.lavender.withValues(alpha: 0.18),
        shape: const StadiumBorder(),
        shadows: [
          BoxShadow(
              color: AppColors.lavender.withValues(alpha: 0.18), blurRadius: 32)
        ],
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.surface.withValues(alpha: 0.8),
      surfaceTintColor: AppColors.transparent,
      indicatorColor: AppColors.lavender.withValues(alpha: 0.18),
      indicatorShape: const StadiumBorder(),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.surface,
      selectedItemColor: AppColors.lavender,
      unselectedItemColor: AppColors.muted,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surfaceRaised,
      selectedColor: AppColors.lavender.withValues(alpha: 0.18),
      labelStyle: const TextStyle(color: AppColors.ivory),
      side: BorderSide(color: AppColors.muted.withValues(alpha: 0.4)),
      shape: const StadiumBorder(),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.surfaceRaised,
      contentTextStyle: const TextStyle(
          fontFamily: 'PlusJakartaSans', color: AppColors.ivory),
      actionTextColor: AppColors.lavender,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surfaceRaised.withValues(alpha: 0.9),
      surfaceTintColor: AppColors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(32),
        side: BorderSide(color: AppColors.lavender.withValues(alpha: 0.2)),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: AppColors.surfaceRaised.withValues(alpha: 0.9),
      surfaceTintColor: AppColors.transparent,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: AppColors.lavender,
      foregroundColor: AppColors.surface,
      shape: const StadiumBorder(),
      elevation: 2,
      focusElevation: 4,
    ),
    dividerTheme:
        DividerThemeData(color: AppColors.lavender.withValues(alpha: 0.12)),
  );

  static OutlineInputBorder _inputBorder(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(999),
        borderSide: BorderSide(color: color),
      );
}
