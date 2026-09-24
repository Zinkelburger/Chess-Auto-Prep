import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/bughouse/hivemind.dart';
import '../../chess/bughouse/table.dart';
import '../../diagnostics/log.dart';
import '../../engines/hivemind_engine.dart';
import 'bughouse_lab.dart';

/// Scores by board and move, A + B's side, with the line after each.
typedef ScoreMap = Map<(BoardNumber, String), ({TableScore score, String pv})>;

/// Where the per-board tables' numbers stand.
sealed class TableScores {
  const TableScores();

  ScoreMap get scores => const {};
}

/// Nothing yet: the engine is starting.
final class ScoresWaiting extends TableScores {
  const ScoresWaiting();
}

/// The engine is scoring each board's likely moves: [done] of [total]
/// searches so far.
final class ScoresSearched extends TableScores {
  const ScoresSearched(this.scores, {required this.done, required this.total});

  @override
  final ScoreMap scores;
  final int done;
  final int total;

  bool get finished => done >= total;
}

final class ScoresFailed extends TableScores {
  const ScoresFailed(this.trouble);

  final EngineTrouble trouble;
}

/// Why the engine could not answer, in the engine's own words.
sealed class EngineTrouble {
  const EngineTrouble(this.reason);

  final String reason;
}

/// It would not start. The tables stop asking until Analyze is pressed.
final class EngineNotStarted extends EngineTrouble {
  const EngineNotStarted(super.reason);
}

/// A search failed: the engine went away or stopped answering.
final class SearchFailed extends EngineTrouble {
  const SearchFailed(super.reason);
}

/// What the engine switch shows: nothing while it is off; while it is on,
/// each team's best joint actions from the last pass that finished, and how
/// long the pass under way thinks for each team.
sealed class EngineLines {
  const EngineLines();
}

final class LinesOff extends EngineLines {
  const LinesOff();
}

/// On: [lines] from the last pass over [position] — empty until the first
/// ends — and [thinking], the pass under way, null once the longest has
/// finished and the engine rests until the table changes.
final class LinesOn extends EngineLines {
  const LinesOn({
    required this.position,
    this.lines = const {},
    this.zero = ZeroSource.assumed,
    this.thinking,
  });

  final TablePosition position;
  final Map<Team, TeamLines> lines;
  final ZeroSource zero;
  final Duration? thinking;
}

/// The engine is on but could not answer; it stays so until switched on
/// again.
final class LinesStopped extends EngineLines {
  const LinesStopped(this.trouble);

  final EngineTrouble trouble;
}

/// One team's side of a pass: its advantage, A + B's side, and up to three
/// joint actions with each one's score. A team with no move on either
/// board has no lines.
typedef TeamLines = ({
  TableScore advantage,
  List<({JointMove move, TableScore score})> rows,
});

/// How long each pass of the engine thinks for each team: Hivemind has no
/// `go infinite` and keeps nothing between searches, so "on" is passes that
/// each think longer than the last, up to the longest, which is kept.
const enginePasses = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
  Duration(seconds: 30),
];

/// How deep the tables' searches go: a 400-node search of the position (it
/// only has to rank the moves), a 200-node search after each move, and the
/// four likeliest moves per board, as BughouseDB's `Analyze locally`. About
/// ten seconds on half of an eight-core desktop.
typedef FillDepth = ({int ownNodes, int childNodes, int topMoves});

const labFillDepth = (ownNodes: 400, childNodes: 200, topMoves: 4);

/// What Hivemind knows about the lab's table, always searched live: the
/// per-board tables' scores and the engine switch's lines.
///
/// One engine answers both, one search at a time, each asked only when the
/// one before has ended. A new position or clock makes whatever the engine
/// was doing stale: its search is cut short and its answer dropped, and a
/// search queued behind it is never asked. Searches the tables made are
/// remembered for the session, so stepping back to a table searched
/// before, or switching back to a clock case, costs nothing. The engine is
/// quit when the mode is left and started again on return.
final class TableSearch extends ChangeNotifier {
  TableSearch({
    required this.lab,
    required Future<HivemindStart> Function() startEngine,
    FillDepth depth = labFillDepth,
    List<Duration> passes = enginePasses,
  }) : _startEngine = startEngine,
       _depth = depth,
       _passes = passes {
    lab.addListener(_labChanged);
  }

  final BughouseLab lab;
  final Future<HivemindStart> Function() _startEngine;
  final FillDepth _depth;
  final List<Duration> _passes;

  TableScores _scores = const ScoresWaiting();
  EngineLines _lines = const LinesOff();

  /// The table the scores and the lines are for: a hover or a flip changes
  /// neither.
  (TablePosition, ClockCase)? _scored;
  bool _open = false;
  bool _resting = false;
  bool _disposed = false;
  bool _engineOn = false;

  /// Bumped by everything that makes the engine's work stale.
  int _generation = 0;

  /// Bumped by every start of the switch's passes, so an older run ends.
  int _run = 0;

  Hivemind? _engine;
  Future<HivemindStart>? _starting;

  /// The search the engine is on, which the next one waits for.
  Future<void> _busy = Future.value();

  /// Whether the search the engine is on is one of the switch's passes.
  bool _passSearching = false;

  /// Done when the tables of the table on screen are filled, or given up:
  /// the switch's passes wait for it, so a long pass never holds the
  /// tables up.
  Future<void> _tablesDone = Future.value();

  /// Why the engine would not start; the tables stop asking until the
  /// engine is switched on again.
  String? _startFailure;

  final _searches = <(int, Team, bool, int, int), HivemindSearched>{};

  TableScores get scores => _scores;
  EngineLines get lines => _lines;

  /// Whether the engine switch is on.
  bool get engineOn => _engineOn;

  /// Starts answering: the mode is on screen. Picking it again while it is
  /// on screen changes nothing.
  void open() {
    if (_open) return;
    _open = true;
    _scored = null;
    _labChanged();
  }

  /// The mode is off screen: the engine is quit. What was found stays, and
  /// the switch stays as it was for the return.
  void close() {
    _open = false;
    _generation++;
    _run++;
    final engine = _engine;
    _engine = null;
    if (engine != null) unawaited(engine.quit());
  }

  /// While the boards follow a match being played, the tables and the
  /// engine do not ask about every position that goes by; they catch up
  /// when it ends.
  void rest(bool resting) {
    if (_resting == resting) return;
    _resting = resting;
    if (resting) {
      _generation++;
      _run++;
      _engine?.stop();
    } else {
      _scored = null;
      _labChanged();
    }
  }

  /// The engine switch: on, both teams are searched in passes that think
  /// longer each time; off, the pass under way is cut short.
  void toggleEngine() {
    _engineOn = !_engineOn;
    _run++;
    if (_engineOn) {
      _startFailure = null;
      if (_scores is ScoresFailed) {
        _scored = null;
        _labChanged();
        return;
      }
      _startRun();
    } else {
      if (_passSearching) _engine?.stop();
      _set(lines: const LinesOff());
    }
  }

  void _labChanged() {
    if (!_open || _resting) return;
    final table = (lab.position, lab.clock);
    if (table == _scored) return;
    _scored = table;
    unawaited(_refresh());
    _startRun();
  }

  /// The switch's passes over the table on screen, from the first.
  void _startRun() {
    final run = ++_run;
    if (!_engineOn || !_open || _resting) return;
    _set(
      lines: LinesOn(position: lab.position, thinking: _passes.first),
    );
    unawaited(_passesOver(run, _generation));
  }

  /// The tables for the table on screen, from the engine.
  Future<void> _refresh() {
    final done = _refreshing();
    _tablesDone = done.then((_) {}, onError: (Object _) {});
    return done;
  }

  Future<void> _refreshing() async {
    final generation = ++_generation;
    _engine?.stop();
    final position = lab.position;
    final clock = lab.clock;
    if (_startFailure case final reason?) {
      _set(scores: ScoresFailed(EngineNotStarted(reason)));
      return;
    }
    await _fill(position, clock, generation);
  }

  /// Scores the likeliest moves of each board: each
  /// team with a move searched once, which gives the zero and ranks its
  /// moves; then each board's top moves played, and the team that answers
  /// searched after each.
  Future<void> _fill(
    TablePosition position,
    ClockCase clock,
    int generation,
  ) async {
    final teams = Team.values.where(position.hasMove).toList();
    _set(scores: ScoresSearched(const {}, done: 0, total: teams.length));
    final own = <Team, HivemindSearched>{};
    final ranking = (nodes: _depth.ownNodes, lines: 8);
    for (final team in teams) {
      final found = await _ask(position, team, clock, ranking, generation);
      if (found == null) return;
      own[team] = found;
      _set(
        scores: ScoresSearched(const {}, done: own.length, total: teams.length),
      );
    }
    final offset = _offset(own, clock).offset;
    final candidates = _candidates(position, own);
    final total = teams.length + candidates.length;
    final scores = <(BoardNumber, String), ({TableScore score, String pv})>{};
    final answer = (nodes: _depth.childNodes, lines: 1);
    for (final (board, uci) in candidates) {
      final played = position.play(board, uci)!;
      final answers = answering(position, board);
      final found = await _ask(
        played.after,
        answers,
        clock,
        answer,
        generation,
      );
      if (found == null) return;
      final top = found.top;
      scores[(board, uci)] = (
        score: top == null
            ? const TableScore()
            : TableScore.of(top, answers, offset),
        pv: [
          '${position.mover(board).letter} ${played.move.san}',
          if (top != null) readablePv(played.after, top.pv),
        ].where((part) => part.isNotEmpty).join(' · '),
      );
      _set(
        scores: ScoresSearched(
          Map.of(scores),
          done: teams.length + scores.length,
          total: total,
        ),
      );
    }
  }

  /// Up to [FillDepth.topMoves] moves per board, from the lines of the
  /// search of the team on move there, in the engine's order.
  List<(BoardNumber, String)> _candidates(
    TablePosition position,
    Map<Team, HivemindSearched> own,
  ) {
    final chosen = <(BoardNumber, String)>[];
    for (final board in BoardNumber.values) {
      final lines = own[position.mover(board).team]?.lines ?? const [];
      final legal = {for (final m in position.legalMoves(board)) m.uci};
      final picks = <String>{};
      for (final line in lines) {
        final first = line.pv.firstOrNull?.on(board);
        final uci = first == null
            ? null
            : position.play(board, first)?.move.uci;
        if (uci != null && legal.contains(uci)) picks.add(uci);
      }
      chosen.addAll(picks.take(_depth.topMoves).map((uci) => (board, uci)));
    }
    return chosen;
  }

  /// The table's search of [team] at [position] under [clock] with
  /// [shape], from memory when it was made before; null when it is stale or
  /// could not be made, the trouble shown.
  Future<HivemindSearched?> _ask(
    TablePosition position,
    Team team,
    ClockCase clock,
    ({int nodes, int lines}) shape,
    int generation,
  ) async {
    if (!_current(generation)) return null;
    final maySit = clock.maySit(team);
    final key = (position.bookKey, team, maySit, shape.nodes, shape.lines);
    if (_searches[key] case final known?) return known;
    final asked = await _search((
      position: position,
      team: team,
      maySit: maySit,
      mustMove: MustMove.either,
      lines: shape.lines,
      budget: NodeBudget(shape.nodes),
    ), () => _current(generation));
    switch (asked) {
      case _Stale():
        return null;
      case _Troubled(:final trouble):
        _set(scores: ScoresFailed(trouble));
        return null;
      case _Answered(:final answer):
        return _searches[key] = answer;
    }
  }

  /// [question] asked once the engine has ended every search before it,
  /// unless it is no longer [wanted] by then.
  Future<_Asked> _search(
    HivemindQuestion question,
    bool Function() wanted, {
    bool pass = false,
  }) async {
    final engine = await _acquire();
    if (!wanted()) return const _Stale();
    if (engine == null) {
      return _Troubled(
        EngineNotStarted(_startFailure ?? 'The bughouse engine did not start.'),
      );
    }
    await _busy;
    if (!wanted()) return const _Stale();
    final searching = engine.search(question);
    _passSearching = pass;
    _busy = searching.then((_) {}, onError: (Object _) {});
    final answer = await searching.whenComplete(() => _passSearching = false);
    if (!wanted()) return const _Stale();
    return switch (answer) {
      HivemindFailed(:final reason) => _Troubled(SearchFailed(reason)),
      final HivemindSearched found => _Answered(found),
    };
  }

  /// The switch's passes over the table on screen: each team with a move
  /// searched for the pass's time, the lines shown as each pass ends, until
  /// the longest pass has been shown or the table changes.
  Future<void> _passesOver(int run, int generation) async {
    bool wanted() =>
        _engineOn && run == _run && _current(generation) && _open && !_resting;
    final position = lab.position;
    final clock = lab.clock;
    final teams = Team.values.where(position.hasMove).toList();
    for (final (i, time) in _passes.indexed) {
      final found = <Team, HivemindSearched>{};
      for (final team in teams) {
        await _tablesDone;
        final asked = await _search(
          (
            position: position,
            team: team,
            maySit: clock.maySit(team),
            mustMove: MustMove.either,
            lines: 3,
            budget: TimeBudget(time),
          ),
          wanted,
          pass: true,
        );
        switch (asked) {
          case _Stale():
            return;
          case _Troubled(:final trouble):
            _engineOn = false;
            _set(lines: LinesStopped(trouble));
            return;
          case _Answered(:final answer):
            found[team] = answer;
        }
      }
      final (:offset, :zero) = _offset(found, clock);
      _set(
        lines: LinesOn(
          position: position,
          lines: {
            for (final MapEntry(key: team, value: answer) in found.entries)
              team: _teamLines(answer, team, offset),
          },
          zero: zero,
          thinking: _passes.elementAtOrNull(i + 1),
        ),
      );
      if (teams.isEmpty) return;
    }
  }

  /// [answer]'s best joint actions for [team], one row per first action.
  TeamLines _teamLines(HivemindSearched answer, Team team, double offset) {
    final top = answer.top;
    final seen = <JointMove>{};
    final rows = [
      for (final line in answer.lines)
        if (line.pv.firstOrNull case final move? when seen.add(move))
          (move: move, score: TableScore.of(line, team, offset)),
    ];
    return (
      advantage: top == null
          ? const TableScore()
          : TableScore.of(top, team, offset),
      rows: rows.take(3).toList(),
    );
  }

  /// The offset both teams' searches agree on, or the level table's when a
  /// team had no move or a mate stands in for a value.
  ({double offset, ZeroSource zero}) _offset(
    Map<Team, HivemindSearched> searches,
    ClockCase clock,
  ) {
    final ab = searches[Team.ab]?.top?.q;
    final cd = searches[Team.cd]?.top?.q;
    if (ab == null || cd == null) {
      return (offset: assumedOffset(clock), zero: ZeroSource.assumed);
    }
    return (offset: (ab + cd) / 2, zero: ZeroSource.measured);
  }

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
        _engine = engine;
        unawaited(engine.exited.then((_) => _lost(engine)));
        return engine;
    }
  }

  /// Lets go of an engine that went away, so the next search starts one.
  void _lost(Hivemind engine) {
    if (identical(_engine, engine)) _engine = null;
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  void _set({TableScores? scores, EngineLines? lines}) {
    if (_disposed) return;
    _scores = scores ?? _scores;
    _lines = lines ?? _lines;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
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

sealed class _Asked {
  const _Asked();
}

final class _Stale extends _Asked {
  const _Stale();
}

final class _Troubled extends _Asked {
  const _Troubled(this.trouble);

  final EngineTrouble trouble;
}

final class _Answered extends _Asked {
  const _Answered(this.answer);

  final HivemindSearched answer;
}

/// A row of a board's table: a legal move and its score from the mover's
/// side, with the line after it.
typedef ScoredMove = ({TableMove move, TableScore score, String pv});

/// Every legal move on [board], scored ones first, best for the mover at
/// the top, then the rest by SAN.
List<ScoredMove> tableRows(
  TablePosition position,
  BoardNumber board,
  ScoreMap scores,
) {
  final mover = position.mover(board).team;
  final rows = [
    for (final move in position.legalMoves(board))
      if (scores[(board, move.uci)] case final scored?)
        (move: move, score: scored.score.forTeam(mover), pv: scored.pv)
      else
        (move: move, score: const TableScore(), pv: ''),
  ];
  rows.sort((a, b) {
    final byScore = b.score.strength.compareTo(a.score.strength);
    return byScore != 0 ? byScore : a.move.san.compareTo(b.move.san);
  });
  return rows;
}
