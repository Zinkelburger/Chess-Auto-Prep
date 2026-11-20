// The player's corpus as the positions table reads it: how a position
// scores, how often each move was played from it, how deep positions are
// listed, and which games are not read at all. (Identity, duplicates,
// repetition and set-up positions are in player_analysis_test.dart.)
import 'package:chess_auto_prep/features/players/player_games.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

const _file = DocumentRef('/games.pgn');

PlayerGame _game(int index, String tags, String moves) => PlayerGame(
  file: _file,
  index: index,
  text: '[Round "$index"]\n$tags\n$moves',
);

void main() {
  test('a position scores wins and losses alike, so one of each is half', () {
    final corpus = buildPlayerCorpus(
      {'alex'},
      [
        _game(0, '[White "Alex"]\n[Black "Bob"]\n[Result "1-0"]\n', '1. e4 1-0'),
        _game(1, '[White "Alex"]\n[Black "Cy"]\n[Result "0-1"]\n', '1. e4 0-1'),
      ],
    );
    final start = corpus.positions.firstWhere((p) => p.ply == 0);
    expect(start.wins, 1);
    expect(start.losses, 1);
    expect(start.score, 0.5);
  });

  test('each move from a position is counted once per game that played it', () {
    final corpus = buildPlayerCorpus(
      {'alex'},
      [
        for (final (i, first) in ['e4', 'e4', 'e4', 'd4'].indexed)
          _game(i, '[White "Alex"]\n[Black "Bob"]\n[Result "*"]\n', '1. $first *'),
      ],
    );
    final start = corpus.positions.firstWhere((p) => p.ply == 0);
    expect(start.count, 4);
    expect(start.moves, {'e2e4': 3, 'd2d4': 1});
  });

  test('positions are listed to the twentieth move of each side and no '
      'further', () {
    // 44 plies, every position new.
    final corpus = buildPlayerCorpus(
      {'alex'},
      [
        _game(
          0,
          '[White "Alex"]\n[Black "Bob"]\n[Result "*"]\n',
          '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 6. Re1 b5 '
              '7. Bb3 d6 8. c3 O-O 9. h3 Nb8 10. d4 Nbd7 11. Nbd2 Bb7 '
              '12. Bc2 Re8 13. Nf1 Bf8 14. Ng3 g6 15. a4 c5 16. d5 c4 '
              '17. Bg5 h6 18. Be3 Nc5 19. Qd2 h5 20. Bg5 Be7 21. Ra3 Nh7 '
              '22. Bxe7 Qxe7 *',
        ),
      ],
    );
    expect(corpus.unread, 0);
    final plies = corpus.positions.map((p) => p.ply).toList()..sort();
    expect(plies, [for (var ply = 0; ply <= 40; ply++) ply]);
  });

  test('a game of another variant, or one with no moves, is not read', () {
    final corpus = buildPlayerCorpus(
      {'alex'},
      [
        _game(
          0,
          '[White "Alex"]\n[Black "Bob"]\n[Variant "Chess960"]\n',
          '1. e4 e5 *',
        ),
        _game(1, '[White "Alex"]\n[Black "Bob"]\n[Result "1-0"]\n', '1-0'),
        _game(2, '[White "Alex"]\n[Black "Bob"]\n', '1. d4 *'),
      ],
    );
    expect(corpus.unread, 2);
    expect(corpus.games.map((g) => g.source.index), [2]);
    expect(corpus.games.single.side, Side.white);
  });
}
