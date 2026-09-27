import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/maia/maia_input.dart';
import 'package:chess_auto_prep/v2/engines/maia/maia_vocabulary.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shipped_vocabulary.dart';

/// Twelve floats per square, in the order `PNBRQKpnbrqk`.
const int _channels = 12;

int _token(int square, int channel) => square * _channels + channel;

/// The moves the mask marks, named by the vocabulary that made it.
Set<String> _maskedMoves(MaiaInput input, MaiaVocabulary vocabulary) => {
  for (var i = 0; i < input.legalMask.length; i++)
    if (input.legalMask[i] > 0) vocabulary.nameAt(i),
};

void main() {
  late final MaiaVocabulary vocabulary;
  setUpAll(() {
    vocabulary = shippedVocabulary();
  });

  test(
    'the board is one channel per occupied square, counting a1 as square 0',
    () {
      final tokens = boardTokens(Fen.initial);
      expect(tokens, hasLength(64 * _channels));
      expect(tokens[_token(0, 3)], 1.0, reason: 'a1 is a white rook');
      expect(tokens[_token(4, 5)], 1.0, reason: 'e1 is a white king');
      expect(tokens[_token(8, 0)], 1.0, reason: 'a2 is a white pawn');
      expect(tokens[_token(60, 11)], 1.0, reason: 'e8 is a black king');
      expect(tokens.where((value) => value == 1.0), hasLength(32));
    },
  );

  test('the first rank of the text lands on squares 56 to 63', () {
    final tokens = boardTokens(const Fen('7k/8/8/8/8/8/8/8 w - - 0 1'));
    expect(tokens[_token(63, 11)], 1.0);
    expect(tokens.where((value) => value == 1.0), hasLength(1));
  });

  test('a digit skips that many files', () {
    final tokens = boardTokens(const Fen('8/8/8/8/8/8/8/4K3 w - - 0 1'));
    expect(tokens[_token(4, 5)], 1.0);
    expect(tokens[_token(0, 5)], 0.0);
  });

  test('White to move is shown as it stands', () {
    final input = encodeForMaia(Fen.initial, vocabulary)!;
    expect(input.mirrored, isFalse);
    expect(input.tokens, boardTokens(Fen.initial));
    expect(_maskedMoves(input, vocabulary), {
      'a2a3',
      'a2a4',
      'b2b3',
      'b2b4',
      'c2c3',
      'c2c4',
      'd2d3',
      'd2d4',
      'e2e3',
      'e2e4',
      'f2f3',
      'f2f4',
      'g2g3',
      'g2g4',
      'h2h3',
      'h2h4',
      'b1a3',
      'b1c3',
      'g1f3',
      'g1h3',
    });
  });

  test('Black to move is turned round first', () {
    const fen = Fen(
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
    );
    final input = encodeForMaia(fen, vocabulary)!;
    expect(input.mirrored, isTrue);
    expect(input.tokens, boardTokens(mirrorFen(fen)));
    final moves = _maskedMoves(input, vocabulary);
    expect(moves, contains('e2e4'), reason: 'Black playing e7e5, mirrored');
    expect(moves, hasLength(20));
  });

  test('castling is the king reaching g1, not the king taking its rook', () {
    const fen = Fen('r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1');
    final moves = _maskedMoves(encodeForMaia(fen, vocabulary)!, vocabulary);
    expect(moves, containsAll(['e1g1', 'e1c1']));
    expect(moves, isNot(contains('e1h1')));
    expect(moves, isNot(contains('e1a1')));
  });

  test('a promotion is four moves and never the bare push', () {
    const fen = Fen('4k3/P7/8/8/8/8/8/4K3 w - - 0 1');
    final moves = _maskedMoves(encodeForMaia(fen, vocabulary)!, vocabulary);
    expect(moves, containsAll(['a7a8q', 'a7a8r', 'a7a8b', 'a7a8n']));
    expect(moves, isNot(contains('a7a8')));
  });

  test('a Black promotion reaches the table through the mirror', () {
    const fen = Fen('4K3/8/8/8/8/8/p7/4k3 b - - 0 1');
    final input = encodeForMaia(fen, vocabulary)!;
    final moves = _maskedMoves(input, vocabulary);
    expect(input.mirrored, isTrue);
    expect(moves, containsAll(['a7a8q', 'a7a8r', 'a7a8b', 'a7a8n']));
  });

  test('text that is not a position has no encoding', () {
    expect(encodeForMaia(const Fen('not a fen'), vocabulary), isNull);
    expect(
      encodeForMaia(const Fen('8/8/8/8/8/8/8/8 w - - 0 1'), vocabulary),
      isNull,
      reason: 'a board with no kings is not a position',
    );
  });

  // Mirroring
  test(
    'flips the ranks, the colours, the side, the rights and the ep square',
    () {
      const fen = Fen(
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
      );
      expect(
        mirrorFen(fen).value,
        'rnbqkbnr/pppp1ppp/8/4p3/8/8/PPPPPPPP/RNBQKBNR w KQkq e6 0 1',
      );
    },
  );

  test('gives one side its own rights back', () {
    const fen = Fen('r3k2r/8/8/8/8/8/8/R3K2R b Kq - 4 12');
    expect(mirrorFen(fen).value, 'r3k2r/8/8/8/8/8/8/R3K2R w Qk - 4 12');
  });

  test('mirroring twice is the position you started with', () {
    const fen = Fen(
      'r1bq1rk1/pp2ppbp/2np1np1/8/2BNP3/2N1B3/PPP2PPP/R2Q1RK1 w - - 3 9',
    );
    expect(mirrorFen(mirrorFen(fen)).value, fen.value);
  });

  test('a position with no rights and no ep square keeps its dashes', () {
    const fen = Fen('8/8/8/8/P7/3k4/8/4K3 b - - 0 2');
    expect(mirrorFen(fen).value, '4k3/8/3K4/p7/8/8/8/8 w - - 0 2');
  });

  test('a four-field FEN comes back with the counters it needs', () {
    const fen = Fen('4k3/8/8/8/8/8/8/4K3 b - -');
    expect(mirrorFen(fen).value, '4k3/8/8/8/8/8/8/4K3 w - - 0 1');
  });

  test('a move on the mirrored board', () {
    expect(mirrorUci('e7e5'), 'e2e4');
    expect(mirrorUci('a7a8q'), 'a2a1q');
    expect(mirrorUci('e8g8'), 'e1g1');
    expect(mirrorUci(mirrorUci('b1c3')), 'b1c3');
  });
}
