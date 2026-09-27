import 'package:flutter/material.dart';

/// Invariant type scale; the active theme supplies every foreground color.
abstract final class AppTypography {
  static const uiFamily = 'Inter';
  static const monoFamily = 'SourceCodePro';
  static const figurineFamily = 'NotoSansSymbols2';
  static const tabularFigures = [FontFeature.tabularFigures()];

  static TextTheme textTheme(ColorScheme colors) {
    final base = ThemeData(brightness: colors.brightness).textTheme.apply(
      bodyColor: colors.onSurface,
      displayColor: colors.onSurface,
    );
    final body = TextStyle(
      fontSize: 14,
      height: 1.4,
      color: colors.onSurface,
      fontFeatures: tabularFigures,
    );
    final caption = TextStyle(
      fontSize: 12,
      height: 1.3,
      color: colors.onSurfaceVariant,
      fontFeatures: tabularFigures,
    );
    final title = TextStyle(
      fontSize: 18,
      height: 1.3,
      fontWeight: FontWeight.w600,
      color: colors.onSurface,
    );
    return base
        .copyWith(
          bodyLarge: body.copyWith(fontSize: 16),
          bodyMedium: body,
          bodySmall: caption,
          titleLarge: title.copyWith(fontSize: 20),
          titleMedium: title.copyWith(fontSize: 16),
          titleSmall: body.copyWith(height: 1.3, fontWeight: FontWeight.w500),
          labelLarge: body.copyWith(fontWeight: FontWeight.w600),
          labelMedium: caption.copyWith(
            fontWeight: FontWeight.w500,
            color: colors.onSurface,
          ),
          labelSmall: caption,
        )
        .apply(
          fontFamily: uiFamily,
          fontFamilyFallback: const [figurineFamily],
        );
  }

  static TextStyle title(BuildContext context) =>
      Theme.of(context).textTheme.titleLarge!.copyWith(fontSize: 18);
  static TextStyle body(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium!;
  static TextStyle bodyStrong(BuildContext context) =>
      body(context).copyWith(fontWeight: FontWeight.w600);
  static TextStyle secondary(BuildContext context) => body(context).copyWith(
    fontSize: 13,
    height: 1.35,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );
  static TextStyle caption(BuildContext context) => Theme.of(context)
      .textTheme
      .bodySmall!
      .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
  static TextStyle mono(BuildContext context) => body(
    context,
  ).copyWith(fontFamily: monoFamily, fontSize: 13, height: 1.35);
}
