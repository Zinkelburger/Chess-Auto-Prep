import 'package:chess_auto_prep/utils/safe_file_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts ordinary cross-platform names', () {
    for (final name in ['Sicilian Najdorf', 'QGD-2026', 'Main (2)', 'A.B']) {
      expect(validateSafeFileName(name), isNull, reason: name);
    }
  });

  test(
    'rejects traversal, separators, controls, and trailing dot or space',
    () {
      for (final name in [
        '.',
        '..',
        '../outside',
        r'folder\file',
        'folder/file',
        'bad\u0000name',
        'trailing.',
        'trailing ',
      ]) {
        expect(validateSafeFileName(name), isNotNull, reason: name);
      }
    },
  );

  test('rejects Windows device names on every platform', () {
    for (final name in ['CON', 'nul', 'COM1', 'LPT9.notes']) {
      expect(validateSafeFileName(name), isNotNull, reason: name);
    }
  });
}
