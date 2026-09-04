/// The one thing that can silently break the bughouse explorer: Dart and
/// Python disagreeing about a FEN.
///
/// The book is keyed by a hash of the two boards' FENs, so a single byte of
/// difference between what `tools/bughouse_db` indexed and what the app looks
/// up is not a wrong answer — it is *no* answer, on every position, with no
/// error anywhere. The fixtures below are the keys Python actually computed
/// (`bughouse_db.poskey`) for lines replayed through its own `DualBoard`; this
/// replays the same lines through [BughouseState] and demands the same number.
library;

import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_book.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// One line, and the key `bughouse_db.poskey.position_key` gives the position
/// it reaches. Board letters are BPGN's: upper case when White moved.
const _lines = <String, ({List<(String, String)> moves, int key})>{
  'the starting position': (moves: [], key: -1476275556734231047),
  'a quiet line on both boards': (
    moves: [
      ('A', 'e4'),
      ('a', 'c5'),
      ('B', 'd4'),
      ('b', 'Nf6'),
      ('A', 'Nf3'),
      ('a', 'd6'),
    ],
    key: 125222357885677211,
  ),
  'captures, which cross to the other board': (
    moves: [
      ('A', 'e4'),
      ('a', 'd5'),
      ('A', 'exd5'),
      ('a', 'Qxd5'),
      ('A', 'Nc3'),
      ('a', 'Qa5'),
      ('B', 'd4'),
      ('b', 'Nf6'),
      ('B', 'c4'),
      ('b', 'e6'),
      ('B', 'Nc3'),
      ('b', 'Bb4'),
      ('B', 'Qc2'),
      ('b', 'Bxc3+'),
      ('B', 'Qxc3'),
    ],
    key: -4390576392843178228,
  ),
  'castling, which drops two letters from the FEN': (
    moves: [
      ('A', 'e4'),
      ('a', 'e5'),
      ('A', 'Nf3'),
      ('a', 'Nc6'),
      ('A', 'Bc4'),
      ('a', 'Bc5'),
      ('A', 'O-O'),
      ('B', 'd4'),
      ('b', 'd5'),
      ('B', 'Nf3'),
      ('b', 'Nf6'),
      ('B', 'Bf4'),
      ('b', 'Bf5'),
    ],
    key: 8846049936349590460,
  ),
  // python-chess writes the en-passant square only when the capture is legal,
  // and dartchess does the same. If either changed its mind, this line is the
  // one that would notice.
  'an en-passant square that is actually capturable': (
    moves: [('A', 'e4'), ('a', 'Nf6'), ('A', 'e5'), ('a', 'd5')],
    key: 68476070537332022,
  ),
  'a drop': (
    moves: [
      ('A', 'e4'),
      ('a', 'd5'),
      ('A', 'exd5'),
      ('B', 'd4'),
      ('b', 'P@e6'),
      ('a', 'Nf6'),
    ],
    key: 6763278611513868733,
  ),
};

BughouseState _replay(List<(String, String)> moves) {
  var state = BughouseState.initial();
  for (final (letter, san) in moves) {
    final which = letter.toUpperCase() == 'A'
        ? BughouseBoard.a
        : BughouseBoard.b;
    final move = state.board(which).parseSan(san);
    expect(move, isNotNull, reason: '$letter:$san did not parse');
    final next = state.playMove(which, move!);
    expect(next, isNotNull, reason: '$letter:$san was not legal');
    state = next!;
  }
  return state;
}

void main() {
  group('the key agrees with the indexer', () {
    _lines.forEach((name, line) {
      test(name, () {
        final state = _replay(line.moves);
        expect(
          bughousePositionKey(state.boardA.fen, state.boardB.fen),
          line.key,
        );
      });
    });
  });

  // dartchess writes a reserve in its own `Role.values` order (pawn, knight,
  // bishop, rook, king, queen); python-chess writes `reversed(PIECE_TYPES)`.
  // The same reserve therefore comes out `[PNQ]` on one side and `[QNP]` on
  // the other, and only once a pocket holds two *different* pieces — which is
  // to say, never in a line short enough to be convenient to write.
  test('a mixed reserve is ordered the way python-chess orders it', () {
    const fenA =
        'rnbqkb1r/ppp1pppp/5n2/3P4/8/8/PPPP1PPP/RNBQKBNR[QNPrbp] w KQkq - 1 3';
    const fenB =
        'rnbqkbnr/pppppppp/4p3/8/3P4/8/PPP1PPPP/RNBQKBNR[bp] w KQkq - 1 2';
    final state = BughouseState.tryParseDualFen('$fenA|$fenB');
    expect(state, isNotNull);

    // dartchess re-emits the reserve in its own order...
    expect(state!.boardA.fen, contains('[PNQpbr]'));
    // ...and the key puts it back in the indexer's.
    expect(
      bughouseKeyFen(state.boardA.fen, state.boardB.fen),
      'rnbqkb1r/ppp1pppp/5n2/3P4/8/8/PPPP1PPP/RNBQKBNR[QNPrbp] w KQkq - | '
      'rnbqkbnr/pppppppp/4p3/8/3P4/8/PPP1PPPP/RNBQKBNR[bp] w KQkq -',
    );
    expect(
      bughousePositionKey(state.boardA.fen, state.boardB.fen),
      -7937666272836285346,
    );
  });

  test('the move counters are path, not position', () {
    const early = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1';
    const late = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 7 40';
    expect(bughousePositionKey(early, early), bughousePositionKey(late, late));
  });

  // Present on a machine that has run `python3 -m bughouse_db index`, absent
  // everywhere else — including CI, where there is no 2 GB corpus to build one
  // from. Both are fine; what is not fine is the app throwing over it.
  group('the book on this machine', () {
    test('opens, or is simply not there', () async {
      final book = await BughouseBook.open();
      if (book == null) return;
      addTearDown(book.close);

      expect(book.status.games, greaterThan(0));
      expect(book.status.maxPly, greaterThan(0));
      expect(book.status.years, isNotEmpty);

      final start = BughouseState.initial();
      final position = book.explore(start.boardA.fen, start.boardB.fen);
      expect(
        position.moves,
        isNotEmpty,
        reason: 'the starting position must be in any book at all',
      );
      expect(position.games, greaterThanOrEqualTo(position.listed));
      // Every continuation from the start is a first move on one board, and
      // by definition White made it.
      expect(position.moves.every((m) => m.mover == Side.white), isTrue);
      // 1.e4 or 1.d4 on board A, at the top of a bughouse archive as much as
      // any other.
      expect(position.moves.first.board, BughouseBoard.a);
    });
  });
}
