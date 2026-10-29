import 'package:chess_auto_prep/chess/bughouse/crazyhouse_pgn.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/chess/bughouse/table_line.dart';
import 'package:chess_auto_prep/chess/bughouse/table_setup.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'table_line_test.dart' show playedLine;

/// [pgn] read back and played by crazyhouse rules, as Lichess imports it:
/// every move must play. Returns the SAN played.
List<String> replayed(String pgn) {
  final game = PgnGame.parsePgn(pgn);
  expect(game.headers['Variant'], 'Crazyhouse');
  final fen = game.headers['FEN'];
  Position position = fen == null
      ? Crazyhouse.initial
      : Crazyhouse.fromSetup(Setup.parseFen(fen));
  final sans = <String>[];
  for (final node in game.moves.mainline()) {
    final move = position.parseSan(node.san);
    expect(move, isNotNull, reason: '${node.san} does not play');
    position = position.play(move!);
    sans.add(node.san);
  }
  return sans;
}

TablePosition table(String text) => (readDualFen(text) as SetupReady).position;

void main() {
  test('from the start: no FEN, numbered SAN, the crazyhouse variant', () {
    final line = playedLine('1e2e4 1d7d5 1e4d5');
    final pgn = crazyhouseLinePgn(line, BoardNumber.one, 3);
    expect(pgn, '[Variant "Crazyhouse"]\n\n1. e4 d5 2. exd5 *');
    expect(replayed(pgn), ['e4', 'd5', 'exd5']);
  });

  test('stops at the move asked for', () {
    final line = playedLine('1e2e4 1d7d5 1e4d5');
    expect(
      crazyhouseLinePgn(line, BoardNumber.one, 2),
      '[Variant "Crazyhouse"]\n\n1. e4 d5 *',
    );
  });

  test('a set-up board carries its hands in the FEN; Black starts with ...', () {
    final start = table(
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR[Nn] b KQkq - 0 1',
    );
    final line = playedLine('1N@e5 1g1f3', TableLine(start));
    final pgn = crazyhouseLinePgn(line, BoardNumber.one, 2);
    expect(pgn, contains('[SetUp "1"]'));
    expect(
      pgn,
      contains(
        '[FEN "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR/Nn b KQkq - 0 1"]',
      ),
    );
    expect(pgn, endsWith('1... N@e5 2. Nf3 *'));
    expect(replayed(pgn), ['N@e5', 'Nf3']);
  });

  test('a pawn drop is P@ and an underpromotion keeps its piece', () {
    final start = table('k7/4P3/8/8/8/8/8/K7[Pp] w - - 0 1');
    final line = playedLine('1e7e8n 1P@b6', TableLine(start));
    final pgn = crazyhouseLinePgn(line, BoardNumber.one, 2);
    expect(pgn, endsWith('1. e8=N P@b6 *'));
    expect(replayed(pgn), ['e8=N', 'P@b6']);
  });

  test('hand edits are comments in a line copied whole from the start', () {
    // The knight Black drops came from a hand edit: Lichess stops there, but
    // the copy keeps every move from the start.
    var line = playedLine('1e2e4');
    line = line.edited(BoardNumber.one, Side.black, Role.knight, 1);
    line = line.edited(BoardNumber.one, Side.white, Role.pawn, 1);
    line = line.edited(BoardNumber.one, Side.white, Role.bishop, 1);
    line = playedLine('1N@f6 1g1f3 1b7b6', line);
    expect(
      crazyhouseLinePgn(line, BoardNumber.one, 4),
      '[Variant "Crazyhouse"]\n\n'
      '1. e4 { +P +B +n } 1... N@f6 2. Nf3 b6 *',
    );
  });

  test('an edit before the first move comes first', () {
    const start = TableLine(TablePosition.initial);
    final line = playedLine(
      '1P@e4',
      start.edited(BoardNumber.one, Side.white, Role.pawn, 2),
    );
    expect(
      crazyhouseLinePgn(line, BoardNumber.one, 1),
      '[Variant "Crazyhouse"]\n\n{ +2P } 1. P@e4 *',
    );
  });
}
