/// Reading a typed opening into a two-board position.
///
/// This is the input the whole feature is aimed at — "1. d4 d5 2. Bf4 for
/// White, show me some games" — so it has to survive being typed the way a
/// player writes a line, and it has to refuse a line that is not one rather
/// than starting a twenty-minute match from a position nobody meant.
library;

import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/widgets/new_bughouse_match_dialog.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a plain line goes on board 1', () {
    final parsed = parseBughouseOpening('1. d4 d5 2. Bf4');

    expect(parsed, isNotNull);
    expect(parsed!.state.boardA.fen, startsWith('rnbqkbnr/ppp1pppp/8/3p4'));
    // Board 2 is untouched: a line for one board says nothing about the other.
    expect(parsed.state.boardB.fen, Crazyhouse.initial.fen);
    expect(parsed.label, 'Board 1: d4 d5 Bf4');
  });

  test('move numbers may be glued on, spaced out, or missing', () {
    final glued = parseBughouseOpening('1.d4 d5 2.Bf4');
    final spaced = parseBughouseOpening('1. d4 1... d5 2. Bf4');
    final bare = parseBughouseOpening('d4 d5 Bf4');

    expect(glued?.state.dualFen, bare?.state.dualFen);
    expect(spaced?.state.dualFen, bare?.state.dualFen);
  });

  test('a prefixed line names its board', () {
    final parsed = parseBughouseOpening('1: e4 e5\n2: d4 d5');

    expect(parsed, isNotNull);
    expect(parsed!.state.boardA.fen, contains('4p3'));
    expect(parsed.state.boardB.fen, contains('3p4'));
    expect(parsed.label, 'Board 1: e4 e5  ·  Board 2: d4 d5');
  });

  test('"Board 2:" and "B:" name the same board', () {
    final long = parseBughouseOpening('Board 2: e4');
    final short = parseBughouseOpening('B: e4');
    expect(long?.state.dualFen, short?.state.dualFen);
    expect(long?.state.boardA.fen, Crazyhouse.initial.fen);
  });

  test('nothing typed is the starting position, not an error', () {
    final parsed = parseBughouseOpening('   ');
    expect(parsed?.state.dualFen, BughouseState.initial().dualFen);
  });

  test('a move that is not legal there is refused', () {
    expect(parseBughouseOpening('1. d4 d5 2. Bf9'), isNull);
    expect(parseBughouseOpening('1. e4 e5 2. Qh9'), isNull);
    // Legal SAN, illegal here: the bishop cannot reach f4 on move one.
    expect(parseBughouseOpening('1. Bf4'), isNull);
  });

  test('a capture in the opening crosses to the other board', () {
    // The rule that makes bughouse bughouse, and the reason the parser plays
    // the moves rather than just setting pieces down.
    final parsed = parseBughouseOpening('1. e4 d5 2. exd5');

    expect(parsed, isNotNull);
    expect(parsed!.state.boardA.pockets?.of(Side.black, Role.pawn), 0);
    expect(parsed.state.boardB.pockets?.of(Side.black, Role.pawn), 1);
  });
}
