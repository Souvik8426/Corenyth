import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';

abstract final class AppTheme {
  static const radiusXs = 6.0;
  static const radiusSm = 10.0;
  static const radiusMd = 14.0;
  static const radiusLg = 18.0;
  static const radiusXl = 24.0;
  static const glassBlur = 24.0;
  static const overlayBlur = 32.0;
  static const glassSaturation = 1.4;
  static const sheetRadius =
      BorderRadius.vertical(top: Radius.circular(radiusXl));
  static const drawerRadius =
      BorderRadius.horizontal(right: Radius.circular(radiusXl));

  static final dark = ThemeData(
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    brightness: Brightness.dark,
    colorScheme: AppColors.scheme,
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.surface,
    iconTheme: const IconThemeData(color: AppColors.ivory),
    hintColor: AppColors.muted,
    focusColor: AppColors.selectedChip,
    hoverColor: AppColors.coreViolet.withValues(alpha: 0.08),
    fontFamily: 'PlusJakartaSans',
    textTheme: const TextTheme(
      displayLarge: TextStyle(
          fontSize: 36,
          fontWeight: FontWeight.w600,
          height: 44 / 36,
          letterSpacing: -1.08),
      displayMedium: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          height: 32 / 24,
          letterSpacing: -0.7),
      displaySmall: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          height: 32 / 24,
          letterSpacing: -0.7),
      headlineLarge: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w600,
          height: 38 / 30,
          letterSpacing: -0.6),
      headlineMedium: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          height: 32 / 24,
          letterSpacing: -0.48),
      headlineSmall: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w700,
          height: 28 / 20,
          letterSpacing: -0.3),
      titleLarge: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w700,
          height: 28 / 20,
          letterSpacing: -0.3),
      titleMedium: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          height: 24 / 15,
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
          fontSize: 12,
          fontWeight: FontWeight.w500,
          height: 16 / 12,
          color: AppColors.tertiaryText,
          letterSpacing: 0.6),
    ),
    filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
            backgroundColor: AppColors.ivory,
            foregroundColor: AppColors.onIvory,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radiusSm)),
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14))),
    elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSm)),
      minimumSize: const Size(48, 48),
      backgroundColor: AppColors.ivory,
      foregroundColor: AppColors.onIvory,
      shadowColor: AppColors.coreCyan.withValues(alpha: 0.08),
      elevation: 1,
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSm)),
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      foregroundColor: AppColors.ivory,
      backgroundColor: AppColors.surfaceRaised,
      side: BorderSide(color: AppColors.glassBorder),
    )),
    textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radiusSm)),
            minimumSize: const Size(48, 48))),
    iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
            foregroundColor: AppColors.ivory, minimumSize: const Size(48, 48))),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      surfaceTintColor: AppColors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusLg),
        side: BorderSide(color: AppColors.cardBorder),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: AppColors.surfaceRaised,
      floatingLabelStyle: const TextStyle(fontSize: 16, color: AppColors.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      hintStyle: const TextStyle(color: AppColors.muted),
      labelStyle: const TextStyle(color: AppColors.muted),
      border: _inputBorder(AppColors.glassBorder),
      enabledBorder: _inputBorder(AppColors.glassBorder),
      disabledBorder: _inputBorder(AppColors.scheme.outlineVariant),
      focusedBorder: _inputBorder(AppColors.coreViolet),
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
        color: AppColors.selectedChip,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm)),
        shadows: [BoxShadow(color: AppColors.selectedChip, blurRadius: 32)],
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: AppColors.transparent,
      indicatorColor: AppColors.selectedChip,
      indicatorShape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSm)),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.surface,
      selectedItemColor: AppColors.coreViolet,
      unselectedItemColor: AppColors.muted,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surfaceRaised,
      selectedColor: AppColors.selectedChip,
      checkmarkColor: AppColors.coreViolet,
      labelStyle: const TextStyle(color: AppColors.ivory),
      side: WidgetStateBorderSide.resolveWith((states) => BorderSide(
          color: states.contains(WidgetState.selected)
              ? AppColors.selectedBorder
              : AppColors.glassBorder)),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSm)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.surfaceRaised,
      contentTextStyle: const TextStyle(
          fontFamily: 'PlusJakartaSans', color: AppColors.ivory),
      actionTextColor: AppColors.coreViolet,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusLg)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surfaceRaised,
      surfaceTintColor: AppColors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusXl),
        side: BorderSide(color: AppColors.glassBorder),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      modalBarrierColor: AppColors.scrim,
      showDragHandle: false,
      backgroundColor: AppColors.transparent,
      surfaceTintColor: AppColors.transparent,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusXl))),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: AppColors.ivory,
      foregroundColor: AppColors.onIvory,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSm)),
      elevation: 2,
      focusElevation: 4,
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? AppColors.coreViolet
              : AppColors.selectedTile),
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? AppColors.onIvory
              : AppColors.muted),
    ),
    listTileTheme: const ListTileThemeData(
      textColor: AppColors.ivory,
      iconColor: AppColors.muted,
      titleTextStyle: TextStyle(
          fontFamily: 'PlusJakartaSans',
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: AppColors.ivory),
      subtitleTextStyle: TextStyle(
          fontFamily: 'PlusJakartaSans',
          fontSize: 12,
          color: AppColors.tertiaryText),
    ),
    dividerTheme: DividerThemeData(color: AppColors.cardBorder),
  );

  static OutlineInputBorder _inputBorder(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusSm),
        borderSide: BorderSide(color: color),
      );
}
