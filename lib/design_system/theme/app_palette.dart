import 'package:flutter/material.dart';

/// Theme construction values. Widgets resolve the active ColorScheme instead.
abstract final class AppPalette {
  static const darkSurface = Color(0xFF121212);
  static const darkPanel = Color(0xFF1E1E1E);
  static const darkContainer = Color(0xFF2A2A2A);
  static const darkInset = Color(0xFF303030);
  static const darkButton = Color(0xFF404040);
  static const darkSelection = Color(0xFF606060);
  static const darkInk = Color(0xFFF2F2F2);
  static const darkMuted = Color(0xFFABABAB);
  static const darkOutline = Color(0xFF616161);
  static const darkDivider = Color(0x24FFFFFF);

  static const dark = ColorScheme.dark(
    surface: darkSurface,
    surfaceDim: darkSurface,
    surfaceBright: darkButton,
    surfaceContainerLowest: darkSurface,
    surfaceContainerLow: darkPanel,
    surfaceContainer: darkContainer,
    surfaceContainerHigh: darkInset,
    surfaceContainerHighest: darkButton,
    onSurfaceVariant: darkMuted,
    outline: darkOutline,
    outlineVariant: darkDivider,
    onSurface: darkInk,
    primary: darkInk,
    onPrimary: darkSurface,
    primaryContainer: darkContainer,
    onPrimaryContainer: darkInk,
    secondary: darkSelection,
    onSecondary: darkInk,
    tertiary: Color(0xFF4DB6AC),
    onTertiary: darkSurface,
    error: Color(0xFFFF807B),
    onError: Color(0xDE000000),
  );

  static const light = ColorScheme.light(
    surface: Color(0xFFF7F7F7),
    surfaceDim: Color(0xFFE6E6E6),
    surfaceBright: Color(0xFFFFFFFF),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF0F0F0),
    surfaceContainer: Color(0xFFECECEC),
    surfaceContainerHigh: Color(0xFFE5E5E5),
    surfaceContainerHighest: Color(0xFFDADADA),
    onSurface: Color(0xFF202020),
    onSurfaceVariant: Color(0xFF505050),
    outline: Color(0xFF777777),
    outlineVariant: Color(0x33000000),
    primary: Color(0xFF202020),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFE5E5E5),
    onPrimaryContainer: Color(0xFF202020),
    secondary: Color(0xFF5A5A5A),
    onSecondary: Color(0xFFFFFFFF),
    tertiary: Color(0xFF00695C),
    onTertiary: Color(0xFFFFFFFF),
    error: Color(0xFF9F2020),
    onError: Color(0xFFFFFFFF),
  );
}
