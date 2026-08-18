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

    test('Chessable Z0 null moves keep the rest of the sideline', () {
      // Lifetime Repertoires intro chapters: a dummy first move, then the
      // intended White setup with Black passing via Z0 between each ply.
      const pgn =
          '1. Z0 ({Welcome} 1. d4 {We intend to play} Z0 2. Nf3 {and} '
          'Z0 3. e3 {next.}) *';
      final vars = _extract(pgn);
      final d4 = vars[0]!.single;
      expect(d4.san, 'd4');
      expect(d4.comment, contains('We intend to play'));
      expect(d4.children.single.san, '--');
      expect(d4.children.single.children.single.san, 'Nf3');
      final e3 =
          d4.children.single.children.single.children.single.children.single;
      expect(e3.san, 'e3');
      expect(e3.comment, contains('next.'));
      expect(
        e3.fen.split(' ')[0],
        'rnbqkbnr/pppppppp/8/8/3P4/4PN2/PPP2PPP/RNBQKB1R',
      );
    });
  });
}
