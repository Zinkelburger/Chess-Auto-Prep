import 'package:chess_auto_prep/services/generation/trap_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TrapExtractor.trapFilePath', () {
    test('replaces a .pgn extension', () {
      expect(
        TrapExtractor.trapFilePath('/reps/benko.pgn'),
        '/reps/benko_traps.json',
      );
      expect(
        TrapExtractor.trapFilePath('/reps/my.lines.pgn'),
        '/reps/my.lines_traps.json',
      );
    });

    test('appends to any other name unchanged', () {
      expect(
        TrapExtractor.trapFilePath('/reps/benko'),
        '/reps/benko_traps.json',
      );
      expect(
        TrapExtractor.trapFilePath('/reps/benko.PGN'),
        '/reps/benko.PGN_traps.json',
      );
    });
  });
}
