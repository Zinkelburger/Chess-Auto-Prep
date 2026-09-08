/// Maia-3 preprocessing: the (64, 12) board tokens, the colour flip that
/// lets one White-to-move network answer for Black, and the legal-move mask
/// over the 4352-move vocabulary.
///
/// The vocabulary (`assets/data/all_moves_maia3.json`) has *no* Black
/// promotions — `a2a1q` is absent, `a7a8q` is present — and encodes castling
/// king-to-destination (`e1g1`), so a mask that skipped the flip, or marked
/// dartchess's king-onto-rook `e1h1`, would silently read the wrong logits.
/// Mirror expectations were cross-checked with python-chess `Board.mirror()`.
library;

import 'package:chess_auto_prep/services/maia/maia_tensor.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show moveToStandardUci;
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

const _vocabSize = 4352;

// One-hot channel per piece letter, in the order the tensor uses.
const _channel = {
  'P': 0,
  'N': 1,
  'B': 2,
  'R': 3,
  'Q': 4,
  'K': 5,
  'p': 6,
  'n': 7,
  'b': 8,
  'r': 9,
  'q': 10,
  'k': 11,
};

int _square(String name) => Square.parse(name)!;

/// UCI → vocabulary index, rebuilt from the public reverse lookup.
late final Map<String, int> _index;

/// Every UCI whose index is set in [mask].
Set<String> _setMoves(List<double> mask) => {
  for (var i = 0; i < mask.length; i++)
    if (mask[i] > 0) MaiaTensor.getMoveFromIndex(i),
};

/// The legal moves of [fen] in the app's standard UCI (king-to-destination
/// castling, lowercase promotion suffix).
Set<String> _legalStandardUcis(String fen) {
  final position = Chess.fromSetup(Setup.parseFen(fen));
  final out = <String>{};
  for (final entry in position.legalMoves.entries) {
    final piece = position.board.pieceAt(entry.key)!;
    for (final to in entry.value.squares) {
      final promo = piece.role == Role.pawn && (to ~/ 8 == 0 || to ~/ 8 == 7);
      if (promo) {
        for (final r in [Role.queen, Role.rook, Role.bishop, Role.knight]) {
          out.add(
            moveToStandardUci(
              position,
              NormalMove(from: entry.key, to: to, promotion: r),
            ),
          );
        }
      } else {
        out.add(
          moveToStandardUci(position, NormalMove(from: entry.key, to: to)),
        );
      }
    }
  }
  return out;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await MaiaTensor.init();
    _index = {
      for (var i = 0; i < _vocabSize; i++) MaiaTensor.getMoveFromIndex(i): i,
    };
    expect(_index, hasLength(_vocabSize), reason: 'vocabulary must load');
  });

  group('boardToMaia3Tokens', () {
    test('start position: one hot per occupied square, a1-indexed', () {
      final t = MaiaTensor.boardToMaia3Tokens(kInitialFEN);
      expect(t, hasLength(64 * 12));
      expect(t.where((v) => v == 1.0).length, 32);
      expect(t[_square('e1') * 12 + _channel['K']!], 1.0);
      expect(t[_square('e8') * 12 + _channel['k']!], 1.0);
      expect(t[_square('d1') * 12 + _channel['Q']!], 1.0);
      expect(t[_square('a2') * 12 + _channel['P']!], 1.0);
      expect(t[_square('h7') * 12 + _channel['p']!], 1.0);
      expect(t[_square('e4') * 12 + _channel['P']!], 0.0);
      // A square holds at most one hot channel.
      for (var s = 0; s < 64; s++) {
        final hot = t
            .sublist(s * 12, s * 12 + 12)
            .where((v) => v == 1.0)
            .length;
        expect(hot, lessThanOrEqualTo(1), reason: 'square $s');
      }
    });

    test('rank 8 of the FEN lands on squares 56-63, rank 1 on 0-7', () {
      final t = MaiaTensor.boardToMaia3Tokens('K7/8/8/8/8/8/8/7k w - - 0 1');
      expect(t[56 * 12 + _channel['K']!], 1.0);
      expect(t[7 * 12 + _channel['k']!], 1.0);
      expect(t.where((v) => v != 0.0).length, 2);
    });

    test('digits skip files and a 4-field FEN is accepted', () {
      final t = MaiaTensor.boardToMaia3Tokens('4k3/8/8/3P4/8/8/8/4K3 b - -');
      expect(t[_square('d5') * 12 + _channel['P']!], 1.0);
      expect(t[_square('e8') * 12 + _channel['k']!], 1.0);
      expect(t.where((v) => v != 0.0).length, 3);
    });
  });

  group('mirrorFEN', () {
    test('flips ranks, colours, side, castling and the ep square', () {
      // Expected strings come from python-chess Board.mirror().
      expect(
        MaiaTensor.mirrorFEN(
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
        ),
        'rnbqkbnr/pppp1ppp/8/4p3/8/8/PPPPPPPP/RNBQKBNR w KQkq e6 0 1',
      );
      expect(
        MaiaTensor.mirrorFEN(
          'r1bq1rk1/pp2ppbp/2np1np1/8/3NP3/2N1B3/PPPQBPPP/R3K2R b KQ - 4 9',
        ),
        'r3k2r/pppqbppp/2n1b3/3np3/8/2NP1NP1/PP2PPBP/R1BQ1RK1 w kq - 4 9',
      );
      expect(
        MaiaTensor.mirrorFEN('4k3/8/8/8/8/8/p7/4K3 b - - 0 1'),
        '4k3/P7/8/8/8/8/8/4K3 w - - 0 1',
      );
    });

    test('is an involution and keeps the move counters', () {
      const fen = 'r3k2r/8/8/8/8/8/8/R3K2R b Kq - 7 31';
      expect(MaiaTensor.mirrorFEN(MaiaTensor.mirrorFEN(fen)), fen);
      expect(MaiaTensor.mirrorFEN(fen).split(' ').sublist(2), [
        'Qk',
        '-',
        '7',
        '31',
      ]);
    });

    test('mirrors a 4-field FEN with default counters', () {
      expect(
        MaiaTensor.mirrorFEN('4k3/8/8/8/8/8/8/4K3 w - -'),
        '4k3/8/8/8/8/8/8/4K3 b - - 0 1',
      );
    });
  });

  test('mirrorMove flips ranks and keeps the promotion suffix', () {
    expect(MaiaTensor.mirrorMove('e7e5'), 'e2e4');
    expect(MaiaTensor.mirrorMove('a7a8q'), 'a2a1q');
    expect(MaiaTensor.mirrorMove('e8g8'), 'e1g1');
    expect(MaiaTensor.mirrorMove(MaiaTensor.mirrorMove('b1c3')), 'b1c3');
  });

  group('vocabulary', () {
    test('is the 64x64 grid plus White promotions only', () {
      expect(MaiaTensor.getMoveFromIndex(0), 'a1a1');
      expect(_index['e2e4'], 796);
      expect(_index.containsKey('a7a8q'), isTrue);
      expect(
        _index.containsKey('a2a1q'),
        isFalse,
        reason: 'Black promotions exist only via the mirror',
      );
      expect(_index.containsKey('e1g1'), isTrue);
      expect(
        MaiaTensor.getMoveFromIndex(_vocabSize),
        '',
        reason: 'out of range',
      );
    });
  });

  group('preprocess', () {
    test('White to move: no flip, mask is exactly the legal moves', () {
      final out = MaiaTensor.preprocess(kInitialFEN, 1500, 1900);
      expect(out['isBlack'], isFalse);
      expect(out['eloSelf'], 1500.0);
      expect(out['eloOppo'], 1900.0);
      expect(out['boardInput'], MaiaTensor.boardToMaia3Tokens(kInitialFEN));
      final mask = out['legalMoves'] as List<double>;
      expect(mask, hasLength(_vocabSize));
      expect(_setMoves(mask), _legalStandardUcis(kInitialFEN));
      expect(_setMoves(mask), hasLength(20));
    });

    test('Black to move: board and mask are the mirrored position', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
      final out = MaiaTensor.preprocess(fen, 1500, 1500);
      expect(out['isBlack'], isTrue);
      expect(
        out['boardInput'],
        MaiaTensor.boardToMaia3Tokens(MaiaTensor.mirrorFEN(fen)),
      );
      final set = _setMoves(out['legalMoves'] as List<double>);
      expect(
        set,
        contains('e2e4'),
        reason: 'Black e7e5 read as the White move',
      );
      // Mirroring every set move back gives exactly Black's legal moves.
      expect(set.map(MaiaTensor.mirrorMove).toSet(), _legalStandardUcis(fen));
    });

    test('castling is masked king-to-destination, not king-onto-rook', () {
      const fen = 'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1';
      final set = _setMoves(
        MaiaTensor.preprocess(fen, 1500, 1500)['legalMoves'] as List<double>,
      );
      expect(set, containsAll(['e1g1', 'e1c1']));
      expect(set, isNot(contains('e1h1')));
      expect(set, isNot(contains('e1a1')));
      // The same for Black after the flip.
      const black = 'r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1';
      final flipped = _setMoves(
        MaiaTensor.preprocess(black, 1500, 1500)['legalMoves'] as List<double>,
      );
      expect(flipped, containsAll(['e1g1', 'e1c1']));
      expect(flipped.map(MaiaTensor.mirrorMove), containsAll(['e8g8', 'e8c8']));
    });

    test('a castling right lost on one side only flips to the right side', () {
      // White may still castle short; Black may not. After the flip the
      // mover (now "White") must have no castling and the opponent short.
      const fen = 'r3k2r/8/8/8/8/8/8/R3K2R b K - 0 1';
      final set = _setMoves(
        MaiaTensor.preprocess(fen, 1500, 1500)['legalMoves'] as List<double>,
      );
      expect(set, isNot(contains('e1g1')));
      expect(set, isNot(contains('e1c1')));
      expect(set.map(MaiaTensor.mirrorMove).toSet(), _legalStandardUcis(fen));
    });

    test('promotions: all four pieces set, the bare push not', () {
      const fen = '4k3/P7/8/8/8/8/8/4K3 w - - 0 1';
      final set = _setMoves(
        MaiaTensor.preprocess(fen, 1500, 1500)['legalMoves'] as List<double>,
      );
      expect(set, containsAll(['a7a8q', 'a7a8r', 'a7a8b', 'a7a8n']));
      expect(set, isNot(contains('a7a8')));
      expect(set, _legalStandardUcis(fen));
    });

    test('Black promotions reach the vocabulary through the mirror', () {
      const fen = '4k3/8/8/8/8/8/p7/4K3 b - - 0 1';
      final set = _setMoves(
        MaiaTensor.preprocess(fen, 1500, 1500)['legalMoves'] as List<double>,
      );
      expect(set, containsAll(['a7a8q', 'a7a8n']));
      expect(set.map(MaiaTensor.mirrorMove).toSet(), _legalStandardUcis(fen));
    });

    test('capturing promotion is masked too', () {
      // b8 is blocked by the knight; a8 and c8 are captures.
      const fen = 'rnb1k3/1P6/8/8/8/8/8/4K3 w - - 0 1';
      final set = _setMoves(
        MaiaTensor.preprocess(fen, 1500, 1500)['legalMoves'] as List<double>,
      );
      expect(set, containsAll(['b7a8q', 'b7c8n', 'b7c8q']));
      expect(set, isNot(contains('b7b8q')));
      expect(set, _legalStandardUcis(fen));
    });

    test('en passant survives the flip', () {
      const white =
          'rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3';
      expect(
        _setMoves(
          MaiaTensor.preprocess(white, 1500, 1500)['legalMoves']
              as List<double>,
        ),
        contains('e5d6'),
      );
      const black =
          'rnbqkbnr/pppp1ppp/8/8/3Pp3/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 3';
      final set = _setMoves(
        MaiaTensor.preprocess(black, 1500, 1500)['legalMoves'] as List<double>,
      );
      expect(set, contains('e5d6'), reason: 'e4xd3 e.p. mirrored');
      expect(set.map(MaiaTensor.mirrorMove).toSet(), _legalStandardUcis(black));
    });

    test('mask matches the legal move set on a spread of positions', () {
      const fens = [
        'r1bq1rk1/pp2ppbp/2np1np1/8/3NP3/2N1B3/PPPQBPPP/R3K2R b KQ - 4 9',
        'r1bq1rk1/pp2ppbp/2np1np1/8/3NP3/2N1B3/PPPQBPPP/R3K2R w KQ - 4 9',
        '8/8/8/8/8/2k5/8/K7 w - - 0 1', // few moves
        'r3k2r/pb1n1p1p/1p2p1p1/2ppP3/3P4/2P2N2/PP3PPP/R3KB1R b KQkq - 0 12',
        '6k1/5ppp/8/8/8/8/5PPP/1R4K1 w - - 0 1', // back-rank mate available
      ];
      for (final fen in fens) {
        final out = MaiaTensor.preprocess(fen, 1500, 1500);
        var set = _setMoves(out['legalMoves'] as List<double>);
        if (out['isBlack'] as bool) {
          set = set.map(MaiaTensor.mirrorMove).toSet();
        }
        expect(set, _legalStandardUcis(fen), reason: fen);
      }
    });

    test('rejects an invalid FEN', () {
      expect(
        () => MaiaTensor.preprocess('not a fen', 1500, 1500),
        throwsException,
      );
      // Two white kings.
      expect(
        () =>
            MaiaTensor.preprocess('4k3/8/8/8/8/8/8/3KK3 w - - 0 1', 1500, 1500),
        throwsException,
      );
    });
  });
}
