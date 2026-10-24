import 'package:flutter/material.dart';

abstract final class AppColors {
  static const background = Color(0xFF000000);
  static const surface = Color(0xFF0F0E14);
  static const surfaceRaised = Color(0xFF17151E);
  static const ivory = Color(0xFFF3ECDD);
  static const muted = Color(0xFFB4AEC0);
  // Legacy mascot colour: keep stable even as UI accents use coreViolet.
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

  static const tertiaryText = Color(0xFF8C8698);
  static const onIvory = Color(0xFF15121C);
  static const userBubble = Color(0xFF1D1A27);
  static const userBubbleBorder = Color(0x24CDBBFF);
  static const successFill = Color(0x1A9FD8B8);
  static const successBorder = Color(0x479FD8B8);
  static const glassFill = Color(0x0EFFFFFF);
  static const glassStrong = Color(0x9E16141E);
  static const glassBorder = Color(0x1AFFFFFF);
  static const glassHighlight = Color(0x1AFFFFFF);
  static const cardBorder = Color(0x12FFFFFF);
  static const hairline = cardBorder;
  static const selectedTile = Color(0x13FFFFFF);
  static const selectedIcon = Color(0x2ECDBBFF);
  static const selectedBorder = Color(0x66CDBBFF);
  static const goldFill = Color(0x1FD4B072);
  static const goldBorder = Color(0x3DD4B072);
  static const selectedChip = Color(0x1ACDBBFF);
  static const scrim = Color(0x80000000);
  static const glassShadow = Color(0x59000000);
  static const avatarLight = Color(0xFF2A2538);
  static const avatarDark = Color(0xFF121019);
  static const auroraViolet = Color(0xFF8E78F0);
  static const auroraSky = Color(0xFF87CEEB);
  static const auroraBlue = Color(0xFF4A90E2);
  static const auroraIndigo = Color(0xFF6E64D8);

  static const scheme = ColorScheme.dark(
    primary: coreViolet,
    onPrimary: onIvory,
    primaryContainer: selectedChip,
    onPrimaryContainer: ivory,
    secondary: coreViolet,
    onSecondary: onIvory,
    secondaryContainer: surfaceRaised,
    onSecondaryContainer: ivory,
    tertiary: coreViolet,
    error: error,
    surface: surface,
    onSurface: ivory,
    onSurfaceVariant: muted,
    surfaceContainerLowest: background,
    surfaceContainerLow: surface,
    surfaceContainer: surfaceRaised,
    surfaceContainerHigh: surfaceRaised,
    surfaceContainerHighest: surfaceRaised,
    outline: tertiaryText,
    outlineVariant: cardBorder,
    surfaceTint: transparent,
    shadow: background,
    scrim: background,
  );
}
