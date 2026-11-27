import 'dart:io';

import 'package:chess_auto_prep/chess/bughouse/hypebeast.dart';
import 'package:chess_auto_prep/chess/bughouse/pv_steps.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/chess/bughouse/table_line.dart';
import 'package:chess_auto_prep/chess/bughouse/table_setup.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/hypebeast_engine.dart';
import 'package:chess_auto_prep/engines/hypebeast_install.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The engine named by `HYPEBEAST_BIN` and its net by `HYPEBEAST_NET` (the
/// bughouse release gate extracts both): the real protocol, spoken through
/// the supervisor, on short searches. Without both it does not run.
final _env = Platform.environment;
final _bin = _env['HYPEBEAST_BIN'] ?? '';
final _net = _env['HYPEBEAST_NET'] ?? '';
final HypeBeastFiles _files = (
  executable: p.absolute(_bin),
  net: p.absolute(_net),
  directory: p.dirname(p.absolute(_bin)),
);
final Object _skip = _bin.isEmpty || _net.isEmpty
    ? 'set HYPEBEAST_BIN and HYPEBEAST_NET to run the real engine'
    : false;

/// The table after 1. e4 d5 2. exd5 on board 1 (D holds the black pawn
/// taken) and 1. d4 on board 2, as the mode plays it.
(TablePosition, List<String>) _game() {
  var line = const TableLine(TablePosition.initial);
  var table = TablePosition.initial;
  for (final (board, uci) in const [
    (BoardNumber.one, 'e2e4'),
    (BoardNumber.one, 'd7d5'),
    (BoardNumber.two, 'd2d4'),
    (BoardNumber.one, 'e4d5'),
  ]) {
    final played = lineMove(table, board, uci)!;
    line = line.played(played);
    table = played.after;
  }
  return (table, line.engineMoves!);
}

Future<HypeBeast> _start(EngineSupervisor engines) async {
  final start = await engines.startHypeBeast(_files);
  if (start case HypeBeastStartFailed(:final reason)) fail(reason);
  return (start as HypeBeastStarted).engine;
}

HypeBeastQuestion _ask(
  TablePosition position,
  BoardNumber board, {
  bool coordination = false,
  int lines = 3,
  ({TablePosition root, List<String> moves})? played,
  HypeBeastBudget budget = const TimeBudget(Duration(milliseconds: 1500)),
}) => (
  position: position,
  played: played,
  board: board,
  lines: lines,
  coordination: coordination,
  threads: 2,
  budget: budget,
);

void main() {
  test(
    'one board alone: three lines of board 1 that play from the table',
    () async {
      final engines = EngineSupervisor();
      addTearDown(engines.dispose);
      final engine = await _start(engines);
      expect(engine.provenance['net'], _files.net);
      final reports = <SeatReport>[];
      final answer =
          await engine.search(
                _ask(TablePosition.initial, BoardNumber.one),
                onReport: reports.add,
              )
              as HypeBeastSearched;
      expect(reports, isNotEmpty);
      final sizes = [for (final report in reports) report.nodes];
      expect(sizes, orderedEquals([...sizes]..sort()));
      final decision = answer.decision!.move!;
      expect(
        TablePosition.initial.legalMoves(BoardNumber.one).map((m) => m.uci),
        contains(decision),
      );
      final rows = seatRows(answer.report, coordinated: false, count: 3);
      // v1.1.2 and later search all three lines, at one depth.
      expect(answer.report.lines, hasLength(3));
      expect(answer.report.lines.map((l) => l.depth).toSet(), hasLength(1));
      expect(rows.map((r) => r.move).toSet(), hasLength(3));
      expect(rows.every((r) => r.cp != null || r.mate != null), isTrue);
      expect(rows.map((r) => r.move), contains(decision));
      for (final row in rows) {
        final steps = pvSteps(TablePosition.initial, BoardNumber.one, row.pv);
        expect(steps, isNotEmpty, reason: 'row ${row.pv} plays');
      }
      await engines.dispose();
      expect(engines.pids, isEmpty);
    },
    skip: _skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'two boards: the table and the game the mode sends are taken, each board '
    'searched for its side to move with the coordinator',
    () async {
      final engines = EngineSupervisor();
      addTearDown(engines.dispose);
      final engine = await _start(engines);
      final (table, moves) = _game();
      expect(moves, ['1e2e4', '1d7d5', '2d2d4', '1e4d5']);
      // The pawn taken on board 1 is in B's hand on board 2, in brackets.
      expect(table.dualFen, contains('[p]'));
      for (final board in BoardNumber.values) {
        final reports = <SeatReport>[];
        final answer =
            await engine.search(
                  _ask(
                    table,
                    board,
                    coordination: true,
                    played: (root: TablePosition.initial, moves: moves),
                  ),
                  onReport: reports.add,
                )
                as HypeBeastSearched;
        final legal = table.legalMoves(board).map((m) => m.uci).toSet();
        final decision = answer.decision!;
        expect(decision.sits || legal.contains(decision.move), isTrue);
        expect(reports.where((r) => r.main != null), isNotEmpty);
        final main = answer.report.main!;
        expect(legal, contains(main.pv.first));
        expect(pvSteps(table, board, main.pv), isNotEmpty);
        final rows = seatRows(
          answer.report,
          coordinated: true,
          decision: decision,
          count: 3,
        );
        expect(rows.first.move, decision.move);
        expect(answer.report.nodes, greaterThan(main.nodes - 1));
      }
      // Told the table alone, as after a hand edit.
      final alone =
          await engine.search(_ask(table, BoardNumber.one, coordination: true))
              as HypeBeastSearched;
      expect(alone.decision, isNotNull);
    },
    skip: _skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a promoted piece and a full hand in the table\'s FEN are read',
    () async {
      final engines = EngineSupervisor();
      addTearDown(engines.dispose);
      final engine = await _start(engines);
      final read = readDualFen(
        'r3k3/8/8/8/8/8/8/Q~3K3[NPp] b - - 0 1|'
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[Qq] w KQkq - 0 1',
      );
      final table = (read as SetupReady).position;
      expect(table.dualFen, contains('Q~'));
      final answer =
          await engine.search(
                _ask(table, BoardNumber.one, budget: const NodeBudget(20000)),
              )
              as HypeBeastSearched;
      final legal = table.legalMoves(BoardNumber.one).map((m) => m.uci).toSet();
      expect(legal, contains(answer.decision!.move));
      for (final line in answer.report.lines) {
        expect(legal, contains(line.pv.first));
      }
    },
    skip: _skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a net that does not load is a start failure, not a weaker engine',
    () async {
      final dir = await Directory.systemTemp.createTemp('hypebeast-net');
      addTearDown(() => dir.delete(recursive: true));
      final engines = EngineSupervisor();
      addTearDown(engines.dispose);
      // A damaged net with the right name: the engine says so and exits.
      final damaged = File(p.join(dir.path, HypeBeastInstall.net))
        ..writeAsBytesSync(List.filled(4096, 7));
      final broken = await engines.startHypeBeast((
        executable: _files.executable,
        net: damaged.path,
        directory: _files.directory,
      ));
      expect(
        (broken as HypeBeastStartFailed).reason,
        'The bughouse engine did not start: its net did not load.',
      );
      // A good net under another name: the engine would play without it.
      final renamed = Link(p.join(dir.path, 'other.nnue'))
        ..createSync(_files.net);
      final classical = await engines.startHypeBeast((
        executable: _files.executable,
        net: renamed.path,
        directory: _files.directory,
      ));
      expect(
        (classical as HypeBeastStartFailed).reason,
        contains('not taken for a bughouse net'),
      );
    },
    skip: _skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
