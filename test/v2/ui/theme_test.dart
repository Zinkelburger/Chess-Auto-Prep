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

  test('moves and evaluations stay monospaced', () {
    expect(monoText.fontFamily, 'SourceCodePro');
    expect(scoreText.fontFamily, 'SourceCodePro');
  });
}
