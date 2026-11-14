// The limits a name is held to, at their edges: the byte budget a name may
// spend, and how far a made-up name is cut.
import 'package:chess_auto_prep/ui/file_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('a typed name', () {
    test('may spend exactly the byte budget, not a byte more', () {
      // Two bytes each in UTF-8: 180 bytes in 90 characters. Literal, so
      // the test does not move with the limit it checks.
      final full = 'é' * 90;
      expect(nameProblem(full), isNull);
      expect(nameProblem('${full}a'), isNotNull);
    });
  });

  group('a made-up name', () {
    test('has the characters a file cannot take replaced', () {
      expect(safeFileName('a/b: c', fallback: 'x'), 'a_b_ c');
      expect(safeFileName('CON', fallback: 'x'), 'x');
    });

    test('from an import is cut at its length, and kept whole up to it', () {
      final whole = 'a' * 100;
      expect(importedName(whole, fallback: 'x'), whole);
      expect(importedName('${whole}b', fallback: 'x'), whole);
    });

    test('from an import is kept whole up to the byte budget', () {
      final whole = 'é' * 90;
      expect(importedName(whole, fallback: 'x'), whole);
      expect(importedName('$wholeé', fallback: 'x'), whole);
    });
  });
}
