import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/bughouse/hivemind.dart';
import '../../chess/bughouse/table.dart';
import '../../diagnostics/log.dart';
import '../../engines/hivemind_engine.dart';
import '../../storage/pending_writes.dart';
import '../../storage/bughouse_books.dart';
import 'bughouse_lab.dart';

/// Scores by board and move, A + B's side, with the line after each.
typedef ScoreMap = Map<(BoardNumber, String), ({TableScore score, String pv})>;

/// Where the per-board tables' numbers stand.
sealed class TableScores {
  const TableScores();

  ScoreMap get scores => const {};
}

/// Nothing yet: the book is being read.
final class ScoresWaiting extends TableScores {
  const ScoresWaiting();
}

/// The book does not have the position for this clock and the engine is
/// off: every move unscored.
final class ScoresNone extends TableScores {
  const ScoresNone();
}

/// The precomputed book has the position: every move scored at once.
final class ScoresFromBook extends TableScores {
  const ScoresFromBook(this.scores, {this.provenance = const {}});

  final Map<String, Object?> provenance;

  @override
  final ScoreMap scores;
}

/// The book does not have it, so the engine is scoring every move, the
/// likeliest first: [done] of [total] so far. It goes into the book when
/// the last is scored.
final class ScoresSearched extends TableScores {
  const ScoresSearched(this.scores, {required this.done, required this.total});

  @override
  final ScoreMap scores;
  final int done;
  final int total;

  bool get finished => done >= total;
}

/// A complete table is saved only once the book confirms its commit.
sealed class AnalysisSave {
  const AnalysisSave();
}

final class AnalysisSaving extends AnalysisSave {
  const AnalysisSaving();
}

final class AnalysisSaved extends AnalysisSave {
  const AnalysisSaved();
}

final class AnalysisSaveFailed extends AnalysisSave {
  const AnalysisSaveFailed(this.detail);

  final String detail;
}

/// Why the engine could not answer, in the engine's own words.
sealed class EngineTrouble {
  const EngineTrouble(this.reason);

  final String reason;
}

/// It would not start.
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

/// How deep the engine scores a position for the book, as the builder
/// does: each team's search of the position (for the zero and to order the
/// moves), then a search after every legal move.
typedef FillDepth = ({int ownNodes, int childNodes});

const labFillDepth = (ownNodes: 1500, childNodes: 200);

/// What Hivemind knows about the lab's table: the per-board tables' scores
/// from the book, and, while the engine switch is on, the engine's lines.
///
/// There is one engine and it runs only while the switch is on: a first
/// short pass for the lines, then, when the book lacks the position for
/// the clock, every move scored and added to the book, then the longer
/// passes. A new position or clock makes whatever the engine was doing
/// stale: its search is cut short and its answer dropped. Searches are
/// remembered for the session. The engine is quit when the mode is left and
/// started again on return.
final class TableSearch extends ChangeNotifier {
  TableSearch({
    required this.lab,
    this.pendingWrites,
    required HivemindBook book,
    required Future<HivemindStart> Function() startEngine,
    FillDepth depth = labFillDepth,
    List<Duration> passes = enginePasses,
  }) : _book = book,
       _startEngine = startEngine,
       _depth = depth,
       _passes = passes {
    lab.addListener(_labChanged);
  }

  final PendingWrites? pendingWrites;
  final BughouseLab lab;
  final HivemindBook _book;
  final Future<HivemindStart> Function() _startEngine;
  final FillDepth _depth;
  final List<Duration> _passes;

  TableScores _scores = const ScoresWaiting();
  EngineLines _lines = const LinesOff();
  String? _bookProblem;

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

  /// Done when the book has been read for the table on screen.
  Future<void> _tablesDone = Future.value();

  /// Why the engine would not start.
  String? _startFailure;

  final _bookAnswers = <int, HivemindLookup>{};

  /// Tables the engine scored this session, shown again when the book
  /// could not keep them.
  final _filled = <(int, ClockCase), ScoresSearched>{};
  final _searches = <(int, Team, bool, int, int), HivemindSearched>{};

  final _entries = <(int, ClockCase), HivemindEntry>{};
  final _saves = <(int, ClockCase), AnalysisSave>{};

  AnalysisSave? get analysisSave => _saves[(lab.position.bookKey, lab.clock)];

  /// Retries the exact completed entry, without rerunning the engine.
  Future<void> retrySave() async {
    final key = (lab.position.bookKey, lab.clock);
    if (_saves[key] is! AnalysisSaveFailed) return;
    final entry = _entries[key];
    if (entry != null) await _save(entry);
  }

  TableScores get scores => _scores;
  EngineLines get lines => _lines;

  /// Whether the engine switch is on.
  bool get engineOn => _engineOn;

  /// Why the book could not be read, when it could not.
  String? get bookProblem => _bookProblem;

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

  /// The engine switch: on, the engine runs over the table on screen; off,
  /// whatever it was doing is cut short.
  void toggleEngine() {
    _engineOn = !_engineOn;
    _run++;
    if (_engineOn) {
      _startFailure = null;
      _startRun();
    } else {
      _engine?.stop();
      _set(lines: const LinesOff());
      unawaited(_refresh());
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

  /// The engine over the table on screen, from its first pass.
  void _startRun() {
    final run = ++_run;
    if (!_engineOn || !_open || _resting) return;
    _set(
      lines: LinesOn(position: lab.position, thinking: _passes.first),
    );
    unawaited(_engineRun(run, _generation));
  }

  /// The tables for the table on screen, from the book.
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
    final key = position.bookKey;
    final answer = _bookAnswers[key] ??= await _book.lookup(position);
    if (!_current(generation)) return;
    _bookProblem = answer is HivemindUnreadable ? answer.detail : null;
    final fromBook = answer is HivemindFound
        ? _bookScores(answer, clock)
        : null;
    _set(
      scores: fromBook != null
          ? ScoresFromBook(
              fromBook,
              provenance:
                  (answer as HivemindFound).provenance[clock] ?? const {},
            )
          : _filled[(key, clock)] ?? const ScoresNone(),
    );
  }

  /// The book's scores for [clock], or null when it has none for it: a
  /// book built for one clock case answers the others from the engine.
  ScoreMap? _bookScores(HivemindFound found, ClockCase clock) {
    final scores = <(BoardNumber, String), ({TableScore score, String pv})>{
      for (final MapEntry(:key, :value) in found.moves.entries)
        key: ?value[clock],
    };
    return scores.isEmpty ? null : scores;
  }

  /// The engine's run over one table: the first pass, then the book's
  /// scores when it lacks them, then the longer passes.
  Future<void> _engineRun(int run, int generation) async {
    bool wanted() =>
        _engineOn && run == _run && _current(generation) && _open && !_resting;
    await _tablesDone;
    if (!wanted()) return;
    final position = lab.position;
    final clock = lab.clock;
    for (final (i, time) in _passes.indexed) {
      if (!await _pass(position, clock, i, time, wanted)) return;
      final complete =
          _scores is ScoresFromBook ||
          (_scores is ScoresSearched && (_scores as ScoresSearched).finished);
      if (i == 0 && !complete) {
        if (!await _fill(position, clock, wanted)) return;
      }
    }
  }

  /// Scores every legal move the way the builder does: each team with a
  /// move searched for the zero and to order its moves; then every move
  /// played, the likeliest first, and the team that answers searched after
  /// it. The finished table goes into the book.
  Future<bool> _fill(
    TablePosition position,
    ClockCase clock,
    bool Function() wanted,
  ) async {
    final watch = Stopwatch()..start();
    final applied = lab.line.applied;
    final fromStart = identical(lab.line.root, TablePosition.initial);
    final teams = Team.values.where(position.hasMove).toList();
    final own = <Team, HivemindSearched>{};
    final ranking = (nodes: _depth.ownNodes, lines: 8);
    for (final team in teams) {
      final found = await _ask(position, team, clock, ranking, wanted);
      if (found == null) return false;
      own[team] = found;
    }
    final reported = <String, Object?>{};
    Map<String, Object?> report(HivemindSearched found) => {
      'nodes': found.top?.nodes,
      'depth': found.top?.depth,
    };
    for (final team in own.keys) {
      reported['root_${team.name}'] = report(own[team]!);
    }
    final offset = _offset(own, clock).offset;
    final order = _moveOrder(position, own);
    final scores = <(BoardNumber, String), ({TableScore score, String pv})>{};
    ScoresSearched progress() => ScoresSearched(
      Map.of(scores),
      done: scores.length,
      total: order.length,
    );
    _set(scores: progress());
    final answer = (nodes: _depth.childNodes, lines: 1);
    for (final (board, uci) in order) {
      final played = position.play(board, uci)!;
      final answers = answering(position, board);
      final found = await _ask(played.after, answers, clock, answer, wanted);
      if (found == null) return false;
      reported['${board.name}:$uci'] = report(found);
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
      _set(scores: progress());
    }
    _filled[(position.bookKey, clock)] = progress();
    final HivemindEntry entry = (
      position: position,
      line: fromStart
          ? applied
                .map(
                  (m) => '${m.board == BoardNumber.one ? 'A' : 'B'}:${m.san}',
                )
                .join(' ')
          : '',
      ply: fromStart ? applied.length : 0,
      clock: clock,
      picks: {
        for (final MapEntry(key: team, value: found) in own.entries)
          if (found.top case final top?)
            team: (
              best: [
                for (final half in teamHalves(
                  position,
                  top.pv.first,
                  team,
                ).values)
                  half,
              ].join(' · '),
              score: TableScore.of(top, team, offset),
              pv: readablePv(position, top.pv),
              offset: offset,
            ),
      },
      moves: scores,
      nodes: _depth.ownNodes,
      childNodes: _depth.childNodes,
      took: watch.elapsed,
      provenance: {
        ...?_engine?.provenance,
        'require_move_on': 'none',
        'root_multipv': 8,
        'child_multipv': 1,
        'reported_searches': reported,
      },
    );
    _entries[(position.bookKey, clock)] = entry;
    await _save(entry);
    return wanted();
  }

  Future<void> _save(HivemindEntry entry) async {
    final key = (entry.position.bookKey, entry.clock);
    _saves[key] = const AnalysisSaving();
    _set();
    final saving = _book.save(entry);
    final result =
        await (pendingWrites?.track(
              (this, key),
              saving,
              label: 'Analysis book',
              obligation: (this, key),
              problem: (outcome) =>
                  outcome is HivemindSaveFailed ? outcome.detail : null,
            ) ??
            saving);
    _saves[key] = switch (result) {
      HivemindSaved() => const AnalysisSaved(),
      HivemindSaveFailed(:final detail) => AnalysisSaveFailed(detail),
    };
    if (result is HivemindSaved) {
      _entries.remove(key);
      _bookAnswers.remove(entry.position.bookKey);
    }
    _set();
  }

  /// Every legal move of both boards, the moves the engine's own lines
  /// start with first, in its order, then the rest.
  List<(BoardNumber, String)> _moveOrder(
    TablePosition position,
    Map<Team, HivemindSearched> own,
  ) {
    final order = <(BoardNumber, String)>[];
    for (final board in BoardNumber.values) {
      final lines = own[position.mover(board).team]?.lines ?? const [];
      final legal = [for (final m in position.legalMoves(board)) m.uci];
      final picks = <String>{};
      for (final line in lines) {
        final first = line.pv.firstOrNull?.on(board);
        final uci = first == null
            ? null
            : position.play(board, first)?.move.uci;
        if (uci != null && legal.contains(uci)) picks.add(uci);
      }
      picks.addAll(legal);
      order.addAll(picks.map((uci) => (board, uci)));
    }
    return order;
  }

  /// The search of [team] at [position] under [clock] with [shape], from
  /// memory when it was made before; null when it is no longer [wanted] or
  /// could not be made, the trouble shown.
  Future<HivemindSearched?> _ask(
    TablePosition position,
    Team team,
    ClockCase clock,
    ({int nodes, int lines}) shape,
    bool Function() wanted,
  ) async {
    if (!wanted()) return null;
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
    ), wanted);
    switch (asked) {
      case _Stale():
        return null;
      case _Troubled(:final trouble):
        _stopped(trouble);
        return null;
      case _Answered(:final answer):
        return _searches[key] = answer;
    }
  }

  /// [question] asked once the engine has ended every search before it,
  /// unless it is no longer [wanted] by then.
  Future<_Asked> _search(
    HivemindQuestion question,
    bool Function() wanted,
  ) async {
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
    _busy = searching.then((_) {}, onError: (Object _) {});
    final answer = await searching;
    if (!wanted()) return const _Stale();
    return switch (answer) {
      HivemindFailed(:final reason) => _Troubled(SearchFailed(reason)),
      final HivemindSearched found => _Answered(found),
    };
  }

  /// One pass over [position]: each team with a move searched for [time],
  /// the lines shown when it ends. False when the run is over.
  Future<bool> _pass(
    TablePosition position,
    ClockCase clock,
    int index,
    Duration time,
    bool Function() wanted,
  ) async {
    final teams = Team.values.where(position.hasMove).toList();
    final found = <Team, HivemindSearched>{};
    for (final team in teams) {
      final asked = await _search((
        position: position,
        team: team,
        maySit: clock.maySit(team),
        mustMove: MustMove.either,
        lines: 3,
        budget: TimeBudget(time),
      ), wanted);
      switch (asked) {
        case _Stale():
          return false;
        case _Troubled(:final trouble):
          _stopped(trouble);
          return false;
        case _Answered(:final answer):
          found[team] = answer;
      }
    }
    final (:offset, :zero) = _offset(found, clock);
    final last = index + 1 >= _passes.length;
    _set(
      lines: LinesOn(
        position: position,
        lines: {
          for (final MapEntry(key: team, value: answer) in found.entries)
            team: _teamLines(answer, team, offset),
        },
        zero: zero,
        thinking: last ? null : _passes[index + 1],
      ),
    );
    return teams.isNotEmpty;
  }

  /// The engine could not answer: the switch goes off and says why.
  void _stopped(EngineTrouble trouble) {
    _engineOn = false;
    final engine = _engine;
    _engine = null;
    if (engine != null) _busy = engine.quit();
    _set(lines: LinesStopped(trouble));
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
