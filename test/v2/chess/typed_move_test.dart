import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/typed_move.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const start = Fen.initial;

  /// White to move with a pawn and a bishop both able to take on c4, a
  /// pawn on e7 about to promote, and castling either way.
  const busy = Fen('8/1k2P3/8/8/2p5/1P1B4/8/R3K2R w KQ - 0 1');

  /// White knights on b1 and f3, both able to go to d2.
  const knights = Fen('4k3/8/8/8/8/5N2/8/1N2K3 w - - 0 1');

  /// Only short castling is legal.
  const shortOnly = Fen('4k3/8/8/8/8/8/8/4K2R w K - 0 1');

  /// The move the words name at once, or null.
  String? resolved(Fen fen, String text) => switch (readTypedMove(fen, text)) {
    Resolved(:final uci) => uci,
    _ => null,
  };

  group('a move plays as soon as the words name it', () {
    test('SAN, as printed or as typed', () {
      expect(resolved(start, 'Nf3'), 'g1f3');
      expect(resolved(start, 'e4'), 'e2e4');
      expect(resolved(start, 'Nf3+'), 'g1f3', reason: 'check signs are free');
      expect(resolved(start, 'Nf3!?'), 'g1f3');
      expect(resolved(start, 'nf3'), 'g1f3', reason: 'case is only a hint');
    });

    test('UCI, in either case', () {
      expect(resolved(start, 'g1f3'), 'g1f3');
      expect(resolved(start, 'E2E4'), 'e2e4');
      expect(resolved(start, 'e2-e4'), 'e2e4', reason: 'long algebraic');
    });

    test('captures with or without the x', () {
      expect(resolved(busy, 'Bxc4'), 'd3c4');
      expect(resolved(busy, 'Bc4'), 'd3c4');
      expect(resolved(busy, 'bxc4'), 'b3c4');
      expect(resolved(busy, 'bc4'), 'b3c4', reason: 'the pawn, as spelled');
    });

    test('a disambiguation the position does not need', () {
      expect(resolved(start, 'Ngf3'), 'g1f3');
      expect(resolved(start, 'N1f3'), 'g1f3');
      expect(resolved(start, 'Ng1f3'), 'g1f3');
    });

    test('a disambiguation the position needs', () {
      expect(resolved(knights, 'Nbd2'), 'b1d2');
      expect(resolved(knights, 'Nfd2'), 'f3d2');
      expect(resolved(knights, 'N3d2'), 'f3d2');
      expect(readTypedMove(knights, 'Nd2'), isA<StillTyping>());
    });

    test('promotions, as SAN or UCI', () {
      expect(resolved(busy, 'e8=Q'), 'e7e8q');
      expect(resolved(busy, 'e8Q'), 'e7e8q');
      expect(resolved(busy, 'e8n'), 'e7e8n');
      expect(resolved(busy, 'e7e8q'), 'e7e8q');
      expect(resolved(busy, 'E7E8R'), 'e7e8r');
    });

    test('castling, every way it is written', () {
      expect(resolved(busy, 'O-O-O'), 'e1c1');
      expect(resolved(busy, '0-0-0'), 'e1c1');
      expect(resolved(busy, 'o-o-o'), 'e1c1');
      expect(resolved(busy, 'e1c1'), 'e1c1');
      expect(resolved(busy, 'e1h1'), 'e1g1', reason: 'the king takes its rook');
      expect(resolved(busy, 'e1a1'), 'e1c1');
      expect(resolved(shortOnly, 'O-O'), 'e1g1', reason: 'nothing longer');
      expect(resolved(shortOnly, '0-0'), 'e1g1');
    });
  });

  group('words that could still name another move wait', () {
    test('short castling while long is legal too', () {
      expect(readTypedMove(busy, 'O-O'), isA<StillTyping>());
      expect(readTypedMove(busy, '0-0'), isA<StillTyping>());
      expect(
        (readTypedMove(busy, 'O-O') as StillTyping).candidates,
        unorderedEquals(['e1g1', 'e1c1']),
      );
    });

    test('the start of a move lists what it could become', () {
      final knight = readTypedMove(start, 'N');
      expect(knight, isA<StillTyping>());
      expect(
        (knight as StillTyping).candidates,
        unorderedEquals(['b1a3', 'b1c3', 'g1f3', 'g1h3']),
      );
      expect(
        (readTypedMove(busy, 'e8') as StillTyping).candidates,
        hasLength(4),
        reason: 'which piece?',
      );
      expect(readTypedMove(start, ''), isA<StillTyping>());
    });
  });

  test('words no legal move is written as', () {
    expect(readTypedMove(start, 'e5'), isA<NoMatch>());
    expect(readTypedMove(start, 'Ke2'), isA<NoMatch>());
    expect(readTypedMove(start, 'z'), isA<NoMatch>());
    expect(readTypedMove(start, 'Nf3f'), isA<NoMatch>());
    expect(readTypedMove(const Fen('not a fen'), 'e4'), isA<NoMatch>());
  });

  group('Enter', () {
    test('plays what the words name, even with a longer move possible', () {
      expect(enteredMove(busy, 'O-O'), 'e1g1');
      expect(enteredMove(start, 'Nf3'), 'g1f3');
    });

    test('plays the one move the words are still the start of', () {
      expect(enteredMove(start, 'Nf'), 'g1f3');
      expect(enteredMove(start, 'g1f'), 'g1f3');
    });

    test('makes a queen of a promotion without its piece', () {
      expect(enteredMove(busy, 'e8'), 'e7e8q');
      expect(enteredMove(busy, 'e7e8'), 'e7e8q');
    });

    test('plays nothing while more than one move is meant', () {
      expect(enteredMove(start, 'N'), isNull);
      expect(enteredMove(knights, 'Nd2'), isNull, reason: 'which knight?');
      expect(enteredMove(start, ''), isNull);
      expect(enteredMove(start, 'e5'), isNull);
    });
  });
}
