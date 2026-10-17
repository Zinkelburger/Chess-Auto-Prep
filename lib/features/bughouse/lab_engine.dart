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
/// first actions as the engine has them now — none before its first
/// report — the score they agree on, and whether the engine is still
/// searching.
final class LinesOn extends LabLines {
  const LinesOn({
    required this.position,
    required this.boards,
    this.teams = const {},
    this.score = const TableScore(),
    this.nodes,
    this.thinking = true,
    this.progress,
  });

  final TablePosition position;
  final LabBoards boards;
  final Map<Team, List<EngineRow>> teams;

  /// A + B's advantage — White's on board 1 — on Hivemind's scale.
  final TableScore score;

  /// The size of the search the rows come from — with two teams shown,
  /// both searches together; null before there are rows.
  final int? nodes;
  final bool thinking;

  /// How far the rows' searches are towards the size they rest at, 0 to 1;
  /// null when that is not known (an engine searching in passes).
  final double? progress;
}

/// The engine is on but could not answer; it stays off until switched on
/// again.
final class LinesStopped extends LabLines {
  const LinesStopped(this.reason);

  /// A sentence for the user.
  final String reason;
}

/// One engine line: its first joint action, A + B's score after it, and
/// the whole line from [table], the table it was searched on — with one
/// board, the partner board given the other team's turn.
typedef EngineRow = ({
  JointMove move,
  TableScore score,
  List<JointMove> pv,
  TablePosition table,
});

/// The size a search of the team shown rests at, at which the engine
/// stops until the table changes. Its lines are reported as it goes.
const labLiveNodes = 100000;

/// The other team's search with one board only measures the score's zero,
/// so it rests sooner and leaves the cores to the search shown.
const labZeroNodes = 20000;

/// An engine that reports nothing while it searches (a build without
/// `live-search.patch`) is asked in passes instead, deeper each time; the
/// switch rests after the last until the table changes. At about 350 nodes
/// a second the first answers in two seconds and the last in about a
/// minute.
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
/// Each team's search is one continuous search on its own engine process
/// (two processes share the engine's cores), shown as it reports and
/// resting at [labLiveNodes]; until the other team's first report the
/// level table's zero stands in. An engine that cannot report as it goes
/// is asked in [labPasses] on one process instead.
///
/// A new position, board count or clock makes whatever the engines were
/// doing stale: their searches are cut short and their answers dropped.
/// Finished searches are remembered for the session. The engines are quit
/// when the mode is left and started again on return.
final class LabEngine extends ChangeNotifier {
  LabEngine({
    required this.lab,
    required this._startEngine,
    this._passes = labPasses,
    this._liveNodes = labLiveNodes,
    this._zeroNodes = labZeroNodes,
  }) {
    lab.addListener(_labChanged);
  }

  final BughouseLab lab;
  final Future<HivemindStart> Function() _startEngine;
  final List<int> _passes;
  final int _liveNodes;
  final int _zeroNodes;

  LabLines _lines = const LinesOff();
  bool _on = false;
  bool _open = false;
  bool _disposed = false;

  /// What the lines were last asked for; a hover or a flip changes nothing.
  (TablePosition, LabBoards, ClockCase)? _asked;

  /// Bumped by everything that makes the engine's work stale.
  int _run = 0;

  /// The engine processes, one per team searched at once; the first also
  /// answers the passes of an engine that cannot report as it goes.
  final _engines = <Hivemind?>[null, null];
  final _starting = <Future<HivemindStart>?>[null, null];

  /// The search each engine is on, which its next one waits for.
  final _busy = <Future<void>>[Future.value(), Future.value()];

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
    _quitAll();
  }

  void _quitAll() {
    for (final (seat, engine) in _engines.indexed) {
      _engines[seat] = null;
      if (engine != null) _busy[seat] = engine.quit();
    }
  }

  void _stopAll() {
    for (final engine in _engines) {
      engine?.stop();
    }
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
      _stopAll();
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
    _stopAll();
    _set(LinesOn(position: lab.position, boards: lab.boards));
    unawaited(_analyse(run, asked));
  }

  Future<void> _analyse(
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
    final first = await _acquire(0);
    if (!wanted()) return;
    if (first == null) {
      _stopped(_startFailure ?? 'The bughouse engine did not start.');
      return;
    }
    if (first.streams) {
      await _live(questions, asked, wanted);
    } else {
      await _passesOver(questions, asked, wanted);
    }
  }

  /// One continuous search per team, each on its own engine, the rows
  /// following every report.
  Future<void> _live(
    List<_Question> questions,
    (TablePosition, LabBoards, ClockCase) asked,
    bool Function() wanted,
  ) async {
    final (position, boards, clock) = asked;
    final latest = <Team, HivemindSearched>{};
    final done = <Team>{};
    int cap(_Question question) => question.shown ? _liveNodes : _zeroNodes;
    void show() {
      if (!wanted()) return;
      // Question order, so the team shown comes first for the score.
      final found = {
        for (final question in questions) question.team: ?latest[question.team],
      };
      final offset = _offset(found, clock);
      final shown = [
        for (final question in questions)
          if (question.shown && found.containsKey(question.team)) question,
      ];
      final nodes = shown.fold(
        0,
        (sum, q) => sum + (found[q.team]!.top?.nodes ?? 0),
      );
      final size = shown.fold(0, (sum, q) => sum + cap(q));
      _set(
        LinesOn(
          position: position,
          boards: boards,
          teams: {
            for (final question in shown)
              question.team: _rows(found[question.team]!, question, offset),
          },
          score: _score(found, offset),
          nodes: shown.isEmpty ? null : nodes,
          thinking: done.length < questions.length,
          progress: size == 0 ? null : (nodes / size).clamp(0.0, 1.0),
        ),
      );
    }

    final searching = <_Question>[];
    for (final question in questions) {
      if (_searches[_key(question, cap(question))] case final known?) {
        latest[question.team] = known;
        done.add(question.team);
      } else {
        searching.add(question);
      }
    }
    show();
    await Future.wait([
      for (final (seat, question) in searching.indexed)
        _stream(seat, question, cap(question), wanted, (answer, finished) {
          latest[question.team] = answer;
          if (finished) done.add(question.team);
          show();
        }),
    ]);
  }

  /// [question] searched on engine [seat] to [nodes], every report handed
  /// to [update]; the finished search is remembered.
  Future<void> _stream(
    int seat,
    _Question question,
    int nodes,
    bool Function() wanted,
    void Function(HivemindSearched answer, bool finished) update,
  ) async {
    final engine = await _acquire(seat);
    if (!wanted()) return;
    if (engine == null) {
      _stopped(_startFailure ?? 'The bughouse engine did not start.');
      return;
    }
    await _busy[seat];
    if (!wanted()) return;
    final searching = engine.search(
      _toAsk(question, nodes),
      onLines: (lines) {
        if (wanted()) update(HivemindSearched(best: null, lines: lines), false);
      },
    );
    _busy[seat] = searching.then((_) {}, onError: (Object _) {});
    final answer = await searching;
    if (!wanted()) return;
    switch (answer) {
      case HivemindFailed(:final reason):
        _stopped('Analysis failed: $reason');
      case final HivemindSearched found:
        _remember(_key(question, nodes), found);
        update(found, true);
    }
  }

  Future<void> _passesOver(
    List<_Question> questions,
    (TablePosition, LabBoards, ClockCase) asked,
    bool Function() wanted,
  ) async {
    final (position, boards, clock) = asked;
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
          if (question.shown)
            question.team: _rows(found[question.team]!, question, offset),
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
    final key = _key(question, nodes);
    if (_searches[key] case final known?) return known;
    final engine = await _acquire(0);
    if (!wanted()) return null;
    if (engine == null) {
      _stopped(_startFailure ?? 'The bughouse engine did not start.');
      return null;
    }
    await _busy[0];
    if (!wanted()) return null;
    final searching = engine.search(_toAsk(question, nodes));
    _busy[0] = searching.then((_) {}, onError: (Object _) {});
    final answer = await searching;
    if (!wanted()) return null;
    switch (answer) {
      case HivemindFailed(:final reason):
        _stopped('Analysis failed: $reason');
        return null;
      case final HivemindSearched found:
        return _remember(key, found);
    }
  }

  HivemindSearched _remember(_SearchKey key, HivemindSearched found) {
    if (_searches.length > _rememberedSearches) _searches.clear();
    return _searches[key] = found;
  }

  static _SearchKey _key(_Question question, int nodes) => (
    question.table.dualFen,
    question.team,
    question.mustMove,
    question.maySit,
    question.lines,
    nodes,
  );

  static HivemindQuestion _toAsk(_Question question, int nodes) => (
    position: question.table,
    team: question.team,
    maySit: question.maySit,
    mustMove: question.mustMove,
    lines: question.lines,
    budget: NodeBudget(nodes),
  );

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
            table: question.table,
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

  /// Engine [seat], started the first time it is needed and again after
  /// it went away; null when it will not start.
  Future<Hivemind?> _acquire(int seat) async {
    final running = _engines[seat];
    if (running != null) return running;
    final starting = _starting[seat] ??= _startEngine();
    final start = await starting;
    if (identical(_starting[seat], starting)) _starting[seat] = null;
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
        // Two waiting on one start share its engine.
        if (_engines[seat] case final other?) return other;
        _startFailure = null;
        _engines[seat] = engine;
        unawaited(engine.exited.then((_) => _lost(seat, engine)));
        return engine;
    }
  }

  /// Lets go of an engine that went away, so the next search starts one.
  void _lost(int seat, Hivemind engine) {
    if (identical(_engines[seat], engine)) _engines[seat] = null;
  }

  /// An engine could not answer: the switch goes off and says why.
  void _stopped(String reason) {
    _on = false;
    _run++;
    _quitAll();
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
    if (_engines.any((engine) => engine != null)) {
      log.i('quit the bughouse engine');
    }
    _quitAll();
    super.dispose();
  }
}

/// Searches kept for the session before the memory starts over.
const _rememberedSearches = 4000;

typedef _SearchKey = (String, Team, MustMove, bool, int, int);

/// One team's search, and whether its rows are shown.
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
    return Crazyhouse.initial.copyWith(turn: turn, pockets: partner.pockets)
        as Crazyhouse;
  }
}
