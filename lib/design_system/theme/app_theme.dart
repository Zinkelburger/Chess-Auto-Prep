import 'package:flutter/material.dart';

import 'app_motion.dart';
import 'app_palette.dart';
import 'app_typography.dart';
import 'workspace_theme.dart';

/// Canonical production themes; Widgetbook uses these same factories.
abstract final class AppTheme {
  static ThemeData dark() => _build(AppPalette.dark);
  static ThemeData light() => _build(AppPalette.light);

  static ThemeData _build(ColorScheme colors) {
    final surfaces = WorkspaceTheme.fromScheme(colors);
    final text = AppTypography.textTheme(colors);
    final button = colors.surfaceContainerHighest;
    return ThemeData(
      colorScheme: colors,
      extensions: [surfaces],
      scaffoldBackgroundColor: surfaces.canvas,
      fontFamily: AppTypography.uiFamily,
      textTheme: text,
      dividerColor: colors.outlineVariant,
      menuTheme: MenuThemeData(
        style: MenuStyle(
          side: WidgetStatePropertyAll(BorderSide(color: colors.outline)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(4)),
          side: BorderSide(color: colors.outline),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        constraints: const BoxConstraints(maxWidth: 480),
        textStyle: text.bodyMedium!.copyWith(fontSize: 13),
        decoration: BoxDecoration(
          color: surfaces.inset,
          borderRadius: const BorderRadius.all(Radius.circular(4)),
          border: Border.all(color: colors.outline),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: surfaces.panel,
        foregroundColor: colors.onSurface,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: colors.onSurface,
          backgroundColor: button,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: colors.onSurface),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(foregroundColor: colors.onSurface),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: colors.onSurface,
          backgroundColor: button,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaces.inset,
        contentTextStyle: text.bodyMedium!.copyWith(fontSize: 15),
        actionTextColor: colors.onSurface,
        closeIconColor: colors.onSurface,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      pageTransitionsTheme: AppMotion.pageTransitions,
      useMaterial3: true,
    );
  }
}
