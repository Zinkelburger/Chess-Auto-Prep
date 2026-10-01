import 'dart:math';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every legal move, a pawn reaching the last rank becoming each piece.
List<Move> _legal(Position position) => [
  for (final MapEntry(key: from, value: targets) in position.legalMoves.entries)
    for (final to in targets.squares)
      if (position.board.roleAt(from) == Role.pawn &&
          (to.rank == Rank.first || to.rank == Rank.eighth))
        for (final role in [Role.queen, Role.knight, Role.rook, Role.bishop])
          NormalMove(from: from, to: to, promotion: role)
      else
        NormalMove(from: from, to: to),
];

Position _at(String fen) => Chess.fromSetup(Setup.parseFen(fen));

void main() {
  test('a position is written as dartchess writes it, through every '
      'position of a thousand random games', () {
    final random = Random(11);
    var positions = 0;
    for (var game = 0; game < 1000; game++) {
      Position position = Chess.initial;
      for (var ply = 0; ply < 160; ply++) {
        expect(fenOf(position).value, position.fen);
        positions++;
        final moves = _legal(position);
        if (moves.isEmpty) break;
        position = position.playUnchecked(moves[random.nextInt(moves.length)]);
      }
    }
    expect(positions, greaterThan(100000));
  });

  test('the en passant square is written only when a pawn can take there', () {
    for (final fen in [
      // A pawn beside the one that just moved can take it.
      'rnbqkbnr/ppp1pppp/8/8/3pP3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 3',
      // Nobody is beside it.
      'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2',
      // The pawn beside it is pinned to its king along the rank.
      '8/8/8/8/k2pP2R/8/8/4K3 b - e3 0 1',
      // The pawn beside it is pinned on the diagonal the capture leaves.
      '4k3/8/8/2KPp3/8/8/8/7b w - e6 0 2',
    ]) {
      final position = _at(fen);
      expect(fenOf(position).value, position.fen, reason: fen);
    }
  });

  test('castling rights are written as dartchess writes them', () {
    for (final fen in [
      'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1',
      'r3k2r/8/8/8/8/8/8/R3K2R w Kq - 0 1',
      'r3k2r/8/8/8/8/8/8/R3K2R b - - 12 40',
      // Rooks that are not the outermost keep their file's letter.
      '1r2k1r1/8/8/8/8/8/8/1R2K1R1 w GBgb - 0 1',
      'rr2k1rr/8/8/8/8/8/8/RR2K1RR w BGbg - 0 1',
      // A king away from the middle, as Chess960 starts.
      'rk5r/8/8/8/8/8/8/RK5R w KQkq - 0 1',
    ]) {
      final position = _at(fen);
      expect(fenOf(position).value, position.fen, reason: fen);
    }
  });

  test('the move counters keep to the range a FEN holds', () {
    final position = Chess.initial.copyWith(halfmoves: 12345, fullmoves: 0);
    expect(fenOf(position).value, position.fen);
    expect(fenOf(position).value, endsWith(' 9999 1'));
  });

  test('another variant is left to dartchess', () {
    final Position position = Crazyhouse.initial;
    expect(fenOf(position).value, position.fen);
  });
}
