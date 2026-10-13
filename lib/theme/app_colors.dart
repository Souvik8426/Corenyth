import 'package:flutter/material.dart';

abstract final class AppColors {
  static const background = Color(0xFF000000);
  static const surface = Color(0xFF121016);
  static const surfaceRaised = Color(0xFF1C1922);
  static const ivory = Color(0xFFF3ECDD);
  static const muted = Color(0xFFA9A3B5);
  static const lavender = Color(0xFFB9A6E8);
  static const coreViolet = Color(0xFFCDBBFF);
  static const coreCyan = Color(0xFFBFE9FF);
  static const gold = Color(0xFFD4B072);
  static const blush = Color(0xFFF2C4CE);
  static const success = Color(0xFF9FD8B8);
  static const error = Color(0xFFE8838F);
  static const transparent = Color(0x00000000);

  // Reserved for AI cognition and ambient glows.
  static const coreGradient = LinearGradient(colors: [coreViolet, coreCyan]);

  static const scheme = ColorScheme.dark(
    primary: lavender,
    onPrimary: surface,
    primaryContainer: lavender,
    onPrimaryContainer: Color(0xFF493973),
    inversePrimary: Color(0xFF655590),
    secondary: gold,
    onSecondary: Color(0xFF422D00),
    secondaryContainer: Color(0xFF5C420E),
    onSecondaryContainer: gold,
    tertiary: blush,
    onTertiary: Color(0xFF452830),
    tertiaryContainer: Color(0xFFD0A5AF),
    onTertiaryContainer: Color(0xFF5A3A42),
    error: error,
    onError: Color(0xFF690005),
    errorContainer: Color(0xFF93000A),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: surface,
    onSurface: ivory,
    onSurfaceVariant: muted,
    surfaceDim: surface,
    surfaceBright: Color(0xFF3B383F),
    surfaceContainerLowest: background,
    surfaceContainerLow: surface,
    surfaceContainer: surfaceRaised,
    surfaceContainerHigh: Color(0xFF2B292F),
    surfaceContainerHighest: Color(0xFF36343A),
    outline: Color(0xFF948F9A),
    outlineVariant: Color(0xFF49454F),
    inverseSurface: ivory,
    onInverseSurface: Color(0xFF322F36),
    surfaceTint: lavender,
    shadow: background,
    scrim: background,
    primaryFixed: Color(0xFFE9DDFF),
    primaryFixedDim: Color(0xFFD0BCFF),
    onPrimaryFixed: Color(0xFF210F49),
    onPrimaryFixedVariant: Color(0xFF4D3D77),
    secondaryFixed: Color(0xFFFFDEA8),
    secondaryFixedDim: Color(0xFFE6C182),
    onSecondaryFixed: Color(0xFF271900),
    onSecondaryFixedVariant: Color(0xFF5C420E),
    tertiaryFixed: Color(0xFFFFD9E1),
    tertiaryFixedDim: Color(0xFFE8BBC5),
    onTertiaryFixed: Color(0xFF2D131B),
    onTertiaryFixedVariant: Color(0xFF5E3E46),
  );
}
