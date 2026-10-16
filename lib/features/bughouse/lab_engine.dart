import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../chess/bughouse/hivemind.dart';
import '../../chess/bughouse/table.dart';
import '../../diagnostics/log.dart';
import '../../engines/hivemind_engine.dart';
import 'bughouse_lab.dart';

/// What the engine switch shows.
sealed class LabLines {
  const LabLines();
}

final class LinesOff extends LabLines {
  const LinesOff();
}

/// On, over [position] as [boards] shows it: each searched team's best
/// first actions from the deepest search that finished — none until the
/// first ends — the score they agree on, and whether a deeper search is
/// under way.
final class LinesOn extends LabLines {
  const LinesOn({
    required this.position,
    required this.boards,
    this.teams = const {},
    this.score = const TableScore(),
    this.nodes,
    this.thinking = true,
  });

  final TablePosition position;
  final LabBoards boards;
  final Map<Team, List<EngineRow>> teams;

  /// A + B's advantage — White's on board 1 — on Hivemind's scale.
  final TableScore score;

  /// The search size the rows come from; null before the first ends.
  final int? nodes;
  final bool thinking;
}

/// The engine is on but could not answer; it stays off until switched on
/// again.
final class LinesStopped extends LabLines {
  const LinesStopped(this.reason);

  /// A sentence for the user.
  final String reason;
}

/// One engine line: its first joint action, A + B's score after it, and
/// the whole line from the table it was searched on.
typedef EngineRow = ({JointMove move, TableScore score, List<JointMove> pv});

/// Each pass searches this many nodes, deeper each time; the switch rests
/// after the last until the table changes. At about 350 nodes a second
/// the first answers in two seconds and the last in about a minute.
const labPasses = [800, 4000, 20000];

/// Rows shown per searched team.
const labLineCount = 3;

/// Hivemind over the table on screen while its switch is on.
///
/// One board: board 1 is searched with its partner board held as it
/// stands, the team on move there required to move on board 1 and nobody
/// allowed to sit. The partner board is given the other team's turn so
/// both teams can be searched, which measures the score's zero (see
/// `hivemind.dart`). Two boards: each team with a move is searched, and may
/// sit when the chosen clock case says so.
///
/// A new position, board count or clock makes whatever the engine was
/// doing stale: its search is cut short and its answer dropped. Searches
/// are remembered for the session. The engine is quit when the mode is
/// left and started again on return.
final class LabEngine extends ChangeNotifier {
  LabEngine({
    required this.lab,
    required Future<HivemindStart> Function() startEngine,
    List<int> passes = labPasses,
  }) : _startEngine = startEngine,
       _passes = passes {
    lab.addListener(_labChanged);
  }

  final BughouseLab lab;
  final Future<HivemindStart> Function() _startEngine;
  final List<int> _passes;

  LabLines _lines = const LinesOff();
  bool _on = false;
  bool _open = false;
  bool _disposed = false;

  /// What the lines were last asked for; a hover or a flip changes nothing.
  (TablePosition, LabBoards, ClockCase)? _asked;

  /// Bumped by everything that makes the engine's work stale.
  int _run = 0;

  Hivemind? _engine;
  Future<HivemindStart>? _starting;

  /// The search the engine is on, which the next one waits for.
  Future<void> _busy = Future.value();

  final _searches = <_SearchKey, HivemindSearched>{};

  LabLines get lines => _lines;

  /// Whether the engine switch is on.
  bool get on => _on;

  /// The mode is on screen. Picking it again while it is changes nothing.
  void open() {
    if (_open) return;
    _open = true;
    _asked = null;
    _labChanged();
  }

  /// The mode is off screen: the engine is quit. What was found stays, and
  /// the switch stays as it was for the return.
  void close() {
    _open = false;
    _run++;
    final engine = _engine;
    _engine = null;
    if (engine != null) unawaited(engine.quit());
  }

  /// The engine switch: on, the engine runs over the table on screen; off,
  /// whatever it was doing is cut short.
  void toggle() {
    _on = !_on;
    _asked = null;
    if (_on) {
      _labChanged();
    } else {
      _run++;
      _engine?.stop();
      _set(const LinesOff());
    }
  }

  void _labChanged() {
    if (!_on || !_open) return;
    // One board is searched with nobody sitting, whatever the clock says.
    final clock = lab.single ? ClockCase.even : lab.clock;
    final asked = (lab.position, lab.boards, clock);
    if (asked == _asked) return;
    _asked = asked;
    final run = ++_run;
    _engine?.stop();
    _set(LinesOn(position: lab.position, boards: lab.boards));
    unawaited(_passesOver(run, asked));
  }

  Future<void> _passesOver(
    int run,
    (TablePosition, LabBoards, ClockCase) asked,
  ) async {
    final (position, boards, clock) = asked;
    bool wanted() => _on && _open && run == _run && !_disposed;
    final questions = boards == LabBoards.one
        ? _oneBoard(position)
        : _twoBoards(position, clock);
    if (questions.isEmpty) {
      _set(LinesOn(position: position, boards: boards, thinking: false));
      return;
    }
    for (final (i, nodes) in _passes.indexed) {
      final found = <Team, HivemindSearched>{};
      for (final question in questions) {
        final answer = await _ask(question, nodes, wanted);
        if (answer == null) return;
        found[question.team] = answer;
      }
      final offset = _offset(found, clock);
      final shown = {
        for (final question in questions)
          if (question.shown) question.team: _rows(found[question.team]!, question, offset),
      };
      _set(
        LinesOn(
          position: position,
          boards: boards,
          teams: shown,
          score: _score(found, offset),
          nodes: nodes,
          thinking: i + 1 < _passes.length,
        ),
      );
    }
  }

  /// Board 1 with its partner board held still: the team on move there
  /// must move on it, and the other team is searched on the partner board
  /// only to measure the zero.
  List<_Question> _oneBoard(TablePosition position) {
    if (position.legalMoves(BoardNumber.one).isEmpty) return const [];
    final mover = position.mover(BoardNumber.one).team;
    final table = TablePosition(
      position.one,
      _partnerFor(position, mover.other),
    );
    return [
      (
        table: table,
        team: mover,
        mustMove: MustMove.one,
        maySit: false,
        lines: labLineCount,
        shown: true,
      ),
      (
        table: table,
        team: mover.other,
        mustMove: MustMove.either,
        maySit: false,
        lines: 1,
        shown: false,
      ),
    ];
  }

  List<_Question> _twoBoards(TablePosition position, ClockCase clock) => [
    for (final team in Team.values)
      if (position.hasMove(team))
        (
          table: position,
          team: team,
          mustMove: MustMove.either,
          maySit: clock.maySit(team),
          lines: labLineCount,
          shown: true,
        ),
  ];

  /// The search of [question] at [nodes], from memory when it was made
  /// before; null when it is no longer [wanted] or could not be made, the
  /// trouble shown.
  Future<HivemindSearched?> _ask(
    _Question question,
    int nodes,
    bool Function() wanted,
  ) async {
    final key = (
      question.table.dualFen,
      question.team,
      question.mustMove,
      question.maySit,
      question.lines,
      nodes,
    );
    if (_searches[key] case final known?) return known;
    final engine = await _acquire();
    if (!wanted()) return null;
    if (engine == null) {
      _stopped(_startFailure ?? 'The bughouse engine did not start.');
      return null;
    }
    await _busy;
    if (!wanted()) return null;
    final searching = engine.search((
      position: question.table,
      team: question.team,
      maySit: question.maySit,
      mustMove: question.mustMove,
      lines: question.lines,
      budget: NodeBudget(nodes),
    ));
    _busy = searching.then((_) {}, onError: (Object _) {});
    final answer = await searching;
    if (!wanted()) return null;
    switch (answer) {
      case HivemindFailed(:final reason):
        _stopped('Analysis failed: $reason');
        return null;
      case final HivemindSearched found:
        if (_searches.length > _rememberedSearches) _searches.clear();
        return _searches[key] = found;
    }
  }

  /// [answer]'s best first actions, one row each, A + B's side.
  List<EngineRow> _rows(
    HivemindSearched answer,
    _Question question,
    double offset,
  ) {
    final seen = <JointMove>{};
    return [
      for (final line in answer.lines)
        if (line.pv.firstOrNull case final move? when seen.add(move))
          (
            move: move,
            score: TableScore.of(line, question.team, offset),
            pv: line.pv,
          ),
    ].take(labLineCount).toList();
  }

  /// A + B's advantage. With the zero measured both teams' best lines give
  /// the same number; a mate found by either wins.
  TableScore _score(Map<Team, HivemindSearched> found, double offset) {
    final scores = [
      for (final MapEntry(key: team, value: answer) in found.entries)
        if (answer.top case final top?) TableScore.of(top, team, offset),
    ];
    return scores.where((s) => s.mate != null).firstOrNull ??
        scores.firstOrNull ??
        const TableScore();
  }

  /// The offset both teams' searches agree on, or the level table's when a
  /// team had no move or a mate stands in for a value.
  double _offset(Map<Team, HivemindSearched> found, ClockCase clock) {
    final ab = found[Team.ab]?.top?.q;
    final cd = found[Team.cd]?.top?.q;
    if (ab == null || cd == null) return assumedOffset(clock);
    return (ab + cd) / 2;
  }

  String? _startFailure;

  /// The engine, started the first time it is needed and again after it
  /// went away; null when it will not start.
  Future<Hivemind?> _acquire() async {
    final running = _engine;
    if (running != null) return running;
    final start = await (_starting ??= _startEngine());
    _starting = null;
    switch (start) {
      case HivemindStartFailed(:final reason):
        _startFailure = reason;
        return null;
      case HivemindStarted(:final engine):
        // Left or gone while it started: nobody is asking any more.
        if (_disposed || !_open) {
          unawaited(engine.quit());
          return null;
        }
        _startFailure = null;
        _engine = engine;
        unawaited(engine.exited.then((_) => _lost(engine)));
        return engine;
    }
  }

  /// Lets go of an engine that went away, so the next search starts one.
  void _lost(Hivemind engine) {
    if (identical(_engine, engine)) _engine = null;
  }

  /// The engine could not answer: the switch goes off and says why.
  void _stopped(String reason) {
    _on = false;
    _run++;
    final engine = _engine;
    _engine = null;
    if (engine != null) _busy = engine.quit();
    _set(LinesStopped(reason));
  }

  void _set(LabLines lines) {
    if (_disposed) return;
    _lines = lines;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _run++;
    lab.removeListener(_labChanged);
    final engine = _engine;
    if (engine != null) {
      log.i('quit the bughouse engine');
      unawaited(engine.quit());
    }
    super.dispose();
  }
}

/// Searches kept for the session before the memory starts over.
const _rememberedSearches = 4000;

typedef _SearchKey = (String, Team, MustMove, bool, int, int);

/// One search a pass makes, and whether its rows are shown.
typedef _Question = ({
  TablePosition table,
  Team team,
  MustMove mustMove,
  bool maySit,
  int lines,
  bool shown,
});

/// The partner board held still for a one-board search, with [team] on
/// move there. When that turn would leave the other side in check, the
/// starting position stands in, with the same hands.
Crazyhouse _partnerFor(TablePosition position, Team team) {
  final partner = position.two;
  final turn = team.sideOn(BoardNumber.two);
  if (partner.turn == turn) return partner;
  final setup = Setup.parseFen(partner.fen);
  try {
    return Crazyhouse.fromSetup(
      Setup(
        board: setup.board,
        pockets: setup.pockets,
        turn: turn,
        castlingRights: setup.castlingRights,
        halfmoves: setup.halfmoves,
        fullmoves: setup.fullmoves,
      ),
    );
  } on PositionSetupException {
    return Crazyhouse.initial.copyWith(
          turn: turn,
          pockets: partner.pockets,
        )
        as Crazyhouse;
  }
}
