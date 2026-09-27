import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table_setup.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter_test/flutter_test.dart';

/// Lines the Python tools played (`tools/mcp/bughouse/board.py`), with the
/// dual FEN, every ply's SAN and UCI, and the book key they reached:
/// written by `test/fixtures/v2_bughouse/generate_python_positions.py`.
final _python =
    (jsonDecode(
              File(
                'test/fixtures/v2_bughouse/python_positions.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>)['cases']!
        as List<Object?>;

/// [line] (`A:e4 B:d4`, SAN) played from [root].
TablePosition played(TablePosition root, String line) {
  var table = root;
  for (final tag in line.split(' ').where((t) => t.isNotEmpty)) {
    final board = tag.startsWith('A') ? BoardNumber.one : BoardNumber.two;
    final san = tag.substring(2);
    final move = table
        .legalMoves(board)
        .firstWhere(
          (m) =>
              m.san.replaceAll(RegExp('[+#]'), '') ==
              san.replaceAll(RegExp('[+#]'), ''),
          orElse: () => throw StateError('$san is not legal on $board'),
        );
    table = table.play(board, move.uci)!.after;
  }
  return table;
}

TablePosition rootOf(String dual) => dual.isEmpty
    ? TablePosition.initial
    : (readDualFen(dual) as SetupReady).position;

void main() {
  group('agrees with the Python tools', () {
    for (final raw in _python) {
      final c = raw as Map<String, Object?>;
      final line = c['line'] as String;
      test('after "${line.isEmpty ? 'the start' : line}"', () {
        var table = rootOf(c['root'] as String);
        for (final ply
            in (c['plies'] as List<Object?>).cast<Map<String, Object?>>()) {
          final board = ply['board'] == 'A' ? BoardNumber.one : BoardNumber.two;
          final move = table.play(board, ply['uci'] as String);
          expect(move, isNotNull, reason: '${ply['uci']} on $board');
          expect(move!.move.san, ply['san']);
          expect(move.move.uci, ply['uci']);
          table = move.after;
        }
        expect(table.keyText, c['key_fen']);
        expect(table.bookKey, c['key']);
      });
    }
  });

  test('a capture goes to the partner on the other board, colour kept', () {
    final table = played(TablePosition.initial, 'A:e4 A:d5 A:exd5');
    // White took a black pawn on board 1: board 2's Black (B) may drop it.
    expect(table.two.pockets!.of(Side.black, Role.pawn), 1);
    expect(table.one.pockets!.of(Side.white, Role.pawn), 0);
  });

  test('a promoted piece crosses as a pawn', () {
    final table = played(
      rootOf('1r2k3/P7/8/8/8/8/1r6/4K3[] w - - 0 1'),
      'A:axb8=Q+ A:Rxb8',
    );
    expect(table.two.pockets!.of(Side.white, Role.pawn), 1);
    expect(table.two.pockets!.of(Side.white, Role.queen), 0);
  });

  test('castling hands no rook over and is written as the king steps', () {
    final table = played(
      TablePosition.initial,
      'A:e4 A:e5 A:Nf3 A:Nc6 A:Bc4 A:Bc5',
    );
    final castle = table
        .legalMoves(BoardNumber.one)
        .where((m) => m.san == 'O-O');
    expect(castle.single.uci, 'e1g1');
    final after = table.play(BoardNumber.one, 'e1h1')!.after;
    expect(after.two.pockets!.size, 0);
  });

  test('drops are listed and written with the piece, pawns too', () {
    final table = played(TablePosition.initial, 'A:e4 A:d5 A:exd5 B:e4');
    final drops = table
        .legalMoves(BoardNumber.two)
        .where((m) => m.uci.contains('@'));
    expect(drops.map((m) => m.san), contains('P@d5'));
    expect(drops.map((m) => m.uci), contains('P@d5'));
    // No pawn on the first or last rank.
    expect(
      drops.any((m) => m.uci.endsWith('1') || m.uci.endsWith('8')),
      isFalse,
    );
  });

  test('an illegal move or drop does not play', () {
    expect(TablePosition.initial.play(BoardNumber.one, 'e2e5'), isNull);
    expect(TablePosition.initial.play(BoardNumber.one, 'N@e4'), isNull);
    expect(TablePosition.initial.play(BoardNumber.one, 'e7e5'), isNull);
  });

  test('seats and teams: A and C on board 1, D and B on board 2', () {
    expect(Seat.of(BoardNumber.one, Side.white), Seat.a);
    expect(Seat.of(BoardNumber.one, Side.black), Seat.c);
    expect(Seat.of(BoardNumber.two, Side.white), Seat.d);
    expect(Seat.of(BoardNumber.two, Side.black), Seat.b);
    expect(Seat.b.team, Team.ab);
    expect(Seat.d.team, Team.cd);
    expect(Team.ab.sideOn(BoardNumber.two), Side.black);
    final table = played(TablePosition.initial, 'A:e4');
    // C on board 1 and D on board 2: C + D hold both moves.
    expect(table.hasMove(Team.ab), isFalse);
    expect(table.hasMove(Team.cd), isTrue);
  });
}
