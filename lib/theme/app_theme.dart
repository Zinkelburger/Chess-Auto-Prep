import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_motion.dart';
import 'app_text_styles.dart';

/// The production theme, shared by the app and contrast regression checks.
abstract final class AppTheme {
  static ThemeData dark() => ThemeData(
    colorScheme: const ColorScheme.dark(
      surface: AppColors.surface,
      surfaceDim: AppColors.surface,
      surfaceBright: AppColors.buttonSurface,
      surfaceContainerLowest: AppColors.surface,
      surfaceContainerLow: AppColors.surfaceElevated,
      surfaceContainer: AppColors.surfaceContainer,
      surfaceContainerHigh: AppColors.surfaceInset,
      surfaceContainerHighest: AppColors.buttonSurface,
      onSurfaceVariant: AppColors.onSurfaceMuted,
      outline: AppColors.outline,
      outlineVariant: AppColors.divider,
      onSurface: AppColors.ink,
      primary: AppColors.ink,
      onPrimary: AppColors.surface,
      primaryContainer: AppColors.surfaceContainer,
      onPrimaryContainer: AppColors.ink,
      secondary: AppColors.surfaceHighlight,
      onSecondary: AppColors.ink,
      tertiary: AppColors.expectimax,
      onTertiary: AppColors.surface,
      error: AppColors.danger,
      onError: AppColors.ink,
    ),
    // Floating surfaces need both separation from the page and legible ink.
    // ColorScheme.dark otherwise falls back to surface for every container tier.
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        side: WidgetStatePropertyAll(BorderSide(color: AppColors.outline)),
      ),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: AppColors.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(4)),
        side: BorderSide(color: AppColors.outline),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      textStyle: AppTextStyles.body.copyWith(fontSize: 13),
      decoration: BoxDecoration(
        color: AppColors.surfaceInset,
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        border: Border.all(color: AppColors.outline),
      ),
    ),
    scaffoldBackgroundColor: AppColors.surface,
    fontFamily: AppTextStyles.uiFamily,
    dividerColor: AppColors.divider,
    // The figurine face only has the chess glyphs, so it is a fallback:
    // ♘ comes from it, every other character from Inter or the mono face.
    textTheme: AppTextStyles.materialTextTheme().apply(
      fontFamilyFallback: const [AppTextStyles.figurineFamily],
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.surfaceElevated,
      foregroundColor: AppColors.ink,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        foregroundColor: AppColors.ink,
        backgroundColor: AppColors.buttonSurface,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.ink),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(foregroundColor: AppColors.ink),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        foregroundColor: AppColors.ink,
        backgroundColor: AppColors.buttonSurface,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.surfaceInset,
      contentTextStyle: AppTextStyles.body.copyWith(fontSize: 15),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    pageTransitionsTheme: AppMotion.pageTransitions,
    useMaterial3: true,
  );
}
