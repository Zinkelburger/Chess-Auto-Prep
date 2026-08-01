import 'package:chess_auto_prep/core/pgn/pgn_variation_extractor.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

Map<int, List<dynamic>> _extract(String pgn) =>
    extractPgnVariations(PgnGame.parsePgn(pgn), Chess.initial);

void main() {
  group('extractPgnVariations', () {
    test('collects sidelines at the ply they branch from', () {
      final vars = _extract('1. e4 e5 (1... c5 2. Nf3) 2. Nf3 *');
      expect(vars.keys, contains(1));
      expect(vars[1]!.single.san, 'c5');
      expect(vars[1]!.single.children.single.san, 'Nf3');
    });

    test(
      'keeps every comment block on a sideline move, not just the first',
      () {
        // dartchess parses two adjacent braces as two comments. Truncating to
        // `first` used to lose the second silently.
        final vars = _extract(
          '1. e4 e5 (1... c5 {Sicilian.} {[%cal Gc5d4]}) *',
        );
        expect(vars[1]!.single.comment, 'Sicilian. [%cal Gc5d4]');
      },
    );

    test('keeps a sideline\'s starting comment instead of dropping it', () {
      final vars = _extract('1. e4 e5 ({The other move:} 1... c5) *');
      expect(vars[1]!.single.comment, 'The other move:');
    });

    test('carries every NAG through to the node', () {
      final vars = _extract('1. e4 e5 (1... c5 \$1 \$14) *');
      expect(vars[1]!.single.nags, const [1, 14]);
    });
  });
}
