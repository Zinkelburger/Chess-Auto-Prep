import 'package:chess_auto_prep/core/pgn/pgn_dummy_mainline.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

PgnGame parse(String pgn) => PgnGame.parsePgn(pgn);

void main() {
  group('promoteNullMoveDummyMainline', () {
    test('promotes a childless Z0 dummy whose only sibling is the lesson', () {
      final game = parse(
        '1. Z0 ({Welcome} 1. d4 {We intend to play} Z0 2. Nf3 {and} '
        'Z0 3. e3 {next.}) *',
      );
      promoteNullMoveDummyMainline(game.moves);

      expect(game.moves.mainline().map((n) => n.san).toList(), [
        'd4',
        '--',
        'Nf3',
        '--',
        'e3',
      ]);
      final d4 = game.moves.children.single.data;
      expect(d4.startingComments?.join(' '), contains('Welcome'));
      expect(d4.comments?.join(' '), contains('We intend to play'));
    });

    test('is a no-op when the mainline is already a real move', () {
      final game = parse('1. d4 Z0 2. Nf3 *');
      promoteNullMoveDummyMainline(game.moves);
      expect(game.moves.mainline().map((n) => n.san).toList(), [
        'd4',
        '--',
        'Nf3',
      ]);
    });

    test('is idempotent', () {
      final game = parse('1. Z0 (1. d4 Z0 2. Nf3) *');
      promoteNullMoveDummyMainline(game.moves);
      promoteNullMoveDummyMainline(game.moves);
      expect(game.moves.mainline().map((n) => n.san).toList(), [
        'd4',
        '--',
        'Nf3',
      ]);
    });

    test('leaves a dummy that has its own continuation alone', () {
      final game = parse('1. Z0 e5 (1. d4) *');
      promoteNullMoveDummyMainline(game.moves);
      expect(game.moves.mainline().first.san, '--');
    });
  });
}
