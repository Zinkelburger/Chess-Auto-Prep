import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final theme = darkTheme();

  /// Every style the theme hands out, by the name a failure should say.
  Map<String, TextStyle?> stylesOf(TextTheme text) => {
    'displayLarge': text.displayLarge,
    'displayMedium': text.displayMedium,
    'displaySmall': text.displaySmall,
    'headlineLarge': text.headlineLarge,
    'headlineMedium': text.headlineMedium,
    'headlineSmall': text.headlineSmall,
    'titleLarge': text.titleLarge,
    'titleMedium': text.titleMedium,
    'titleSmall': text.titleSmall,
    'bodyLarge': text.bodyLarge,
    'bodyMedium': text.bodyMedium,
    'bodySmall': text.bodySmall,
    'labelLarge': text.labelLarge,
    'labelMedium': text.labelMedium,
    'labelSmall': text.labelSmall,
  };

  test('every style the theme carries is in the app font', () {
    for (final style in stylesOf(theme.textTheme).entries) {
      if (style.value == null) continue;
      expect(
        style.value!.fontFamily,
        'Inter',
        reason: '${style.key} would be shown in the platform font',
      );
    }
  });

  test('the sizes the app reads by are the ones it sets', () {
    final text = theme.textTheme;
    expect(text.titleMedium?.fontSize, 18);
    expect(text.bodyMedium?.fontSize, 14);
    expect(text.bodySmall?.fontSize, 13);
    expect(text.labelSmall?.fontSize, 12);
    expect(text.labelSmall?.color, text.bodySmall?.color);
  });

  test('accent and button labels contrast with their backgrounds', () {
    double contrast(Color a, Color b) {
      final first = a.computeLuminance();
      final second = b.computeLuminance();
      return first > second
          ? (first + 0.05) / (second + 0.05)
          : (second + 0.05) / (first + 0.05);
    }

    final colors = theme.colorScheme;
    for (final surface in [colors.surface, colors.surfaceContainerHighest]) {
      expect(contrast(colors.primary, surface), greaterThanOrEqualTo(4.5));
    }
    expect(
      contrast(colors.primary, colors.onPrimary),
      greaterThanOrEqualTo(4.5),
    );
    for (final style in [theme.filledButtonTheme.style!]) {
      expect(
        contrast(
          style.foregroundColor!.resolve({})!,
          style.backgroundColor!.resolve({})!,
        ),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  test('moves and evaluations stay monospaced', () {
    expect(monoText.fontFamily, 'SourceCodePro');
  });
}
