import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/bughouse/hivemind.dart';
import '../../chess/bughouse/table.dart';
import '../../diagnostics/log.dart';
import '../../engines/hivemind_engine.dart';
import '../../storage/bughouse_books.dart';
import 'bughouse_lab.dart';

/// Scores by board and move, A + B's side, with the line after each.
typedef ScoreMap = Map<(BoardNumber, String), ({TableScore score, String pv})>;

/// Where the per-board tables' numbers stand.
sealed class TableScores {
  const TableScores();

  ScoreMap get scores => const {};
}

/// Nothing yet: the book is being read or the engine started.
final class ScoresWaiting extends TableScores {
  const ScoresWaiting();
}

/// The precomputed book has the position: every move scored at once.
final class ScoresFromBook extends TableScores {
  const ScoresFromBook(this.scores);

  @override
  final ScoreMap scores;
}

/// The book does not have it, so the engine is scoring each board's likely
/// moves: [done] of [total] searches so far.
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

sealed class Analysis {
  const Analysis();
}

final class AnalysisIdle extends Analysis {
  const AnalysisIdle();
}

/// Searching for [team]: ours first, then the other team for the zero.
final class AnalysisRunning extends Analysis {
  const AnalysisRunning(this.team);

  final Team team;
}

/// [team] has no move on either board: nothing to ask.
final class AnalysisNoMove extends Analysis {
  const AnalysisNoMove(this.team);

  final Team team;
}

final class AnalysisFailed extends Analysis {
  const AnalysisFailed(this.trouble);

  final EngineTrouble trouble;
}

/// What Analyze found for [team] at [position]: its advantage, A + B's
/// side, where the zero came from, and up to three joint actions with each
/// one's score.
final class AnalysisDone extends Analysis {
  const AnalysisDone({
    required this.position,
    required this.team,
    required this.advantage,
    required this.zero,
    required this.rows,
  });

  final TablePosition position;
  final Team team;
  final TableScore advantage;
  final ZeroSource zero;
  final List<({JointMove move, TableScore score})> rows;
}

/// How deep the lab's own searches go when the book has no position: a
/// quarter of the book builder's search of the position (it only has to
/// rank the moves), its search after each move as it is, and the four
/// likeliest moves per board, as BughouseDB's `Analyze locally`. About ten
/// seconds on half of an eight-core desktop.
typedef FillDepth = ({int ownNodes, int childNodes, int topMoves});

const labFillDepth = (ownNodes: 400, childNodes: 200, topMoves: 4);

/// What Hivemind knows about the lab's table: the per-board tables' scores
/// from the precomputed book, or from the engine when the book does not
/// have the position, and the Analyze search.
///
/// One engine answers both, one search at a time, each asked only when the
/// one before has ended. A new position or clock makes whatever the engine
/// was doing stale: its search is cut short and its answer dropped, and a
/// search queued behind it is never asked. Searches already made are
/// remembered for the session, so stepping back to a table searched
/// before, or switching back to a clock case, costs nothing. The engine is
/// quit when the mode is left and started again on return.
final class TableSearch extends ChangeNotifier {
  TableSearch({
    required this.lab,
    required HivemindBook book,
    required Future<HivemindStart> Function() startEngine,
    FillDepth depth = labFillDepth,
  }) : _book = book,
       _startEngine = startEngine,
       _depth = depth {
    lab.addListener(_labChanged);
  }

  final BughouseLab lab;
  final HivemindBook _book;
  final Future<HivemindStart> Function() _startEngine;
  final FillDepth _depth;

  TableScores _scores = const ScoresWaiting();
  Analysis _analysis = const AnalysisIdle();
  String? _bookProblem;

  /// The table the scores are for, and the question Analyze answered: a
  /// hover or a flip changes neither, a chip changes one.
  (TablePosition, ClockCase)? _scored;
  Object? _analysed;
  bool _open = false;
  bool _resting = false;
  bool _disposed = false;

  /// Bumped by everything that makes the engine's work stale.
  int _generation = 0;

  Hivemind? _engine;
  Future<HivemindStart>? _starting;

  /// The search the engine is on, which the next one waits for.
  Future<void> _busy = Future.value();

  /// Why the engine would not start; the tables stop asking until Analyze
  /// is pressed again.
  String? _startFailure;
  bool _stopAsked = false;

  final _bookAnswers = <int, HivemindLookup>{};
  final _searches = <(int, Team, bool, int, int), HivemindSearched>{};

  TableScores get scores => _scores;
  Analysis get analysis => _analysis;

  /// Why the book could not be read, when it could not.
  String? get bookProblem => _bookProblem;

  /// Starts answering: the mode is on screen.
  void open() {
    _open = true;
    _scored = null;
    _labChanged();
  }

  /// The mode is off screen: the engine is quit. What was found stays.
  void close() {
    _open = false;
    _generation++;
    final engine = _engine;
    _engine = null;
    if (engine != null) unawaited(engine.quit());
    if (_analysis is AnalysisRunning) _set(analysis: const AnalysisIdle());
  }

  /// While the boards follow a match being played, the tables do not ask
  /// about every position that goes by; they catch up when it ends.
  void rest(bool resting) {
    if (_resting == resting) return;
    _resting = resting;
    if (resting) {
      _generation++;
      _engine?.stop();
      if (_analysis is AnalysisRunning) _set(analysis: const AnalysisIdle());
    } else {
      _scored = null;
      _labChanged();
    }
  }

  void _labChanged() {
    if (!_open || _resting) return;
    final table = (lab.position, lab.clock);
    final question = (table, lab.team, lab.mustMove, lab.budget);
    final running = _analysis is AnalysisRunning;
    if (_analysed != null && question != _analysed) {
      _analysed = null;
      _set(analysis: const AnalysisIdle());
    }
    // A running Analyze took the engine from the tables; they take it back.
    if (table != _scored || (running && _analysed == null)) {
      _scored = table;
      unawaited(_refresh());
    }
  }

  /// The tables for the table on screen: the book, else the engine.
  Future<void> _refresh() async {
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
    if (fromBook != null) {
      _set(scores: ScoresFromBook(fromBook));
      return;
    }
    if (_startFailure case final reason?) {
      _set(scores: ScoresFailed(EngineNotStarted(reason)));
      return;
    }
    await _fill(position, clock, generation);
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

  /// Scores the likeliest moves of each board the way the book does: each
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
    ), generation);
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

  /// [question] asked once the engine has ended every search before it.
  Future<_Asked> _search(HivemindQuestion question, int generation) async {
    final engine = await _acquire();
    if (!_current(generation)) return const _Stale();
    if (engine == null) {
      return _Troubled(
        EngineNotStarted(_startFailure ?? 'The bughouse engine did not start.'),
      );
    }
    await _busy;
    if (!_current(generation)) return const _Stale();
    final searching = engine.search(question);
    _busy = searching.then((_) {}, onError: (Object _) {});
    final answer = await searching;
    if (!_current(generation)) return const _Stale();
    return switch (answer) {
      HivemindFailed(:final reason) => _Troubled(SearchFailed(reason)),
      final HivemindSearched found => _Answered(found),
    };
  }

  /// Analyze: [BughouseLab.team]'s search for the Search chip's time, with
  /// its board that must be moved on, then the other team's for the zero.
  Future<void> analyze() async {
    if (!_open || _resting) return;
    final generation = ++_generation;
    _engine?.stop();
    _startFailure = null;
    _stopAsked = false;
    final position = lab.position;
    final team = lab.team;
    _analysed = ((position, lab.clock), team, lab.mustMove, lab.budget);
    if (!position.hasMove(team)) {
      _set(analysis: AnalysisNoMove(team));
      return _resume(generation);
    }
    _set(analysis: AnalysisRunning(team));
    final ours = await _analyse(position, team, lab.mustMove, 3, generation);
    if (ours == null) return _resume(generation);
    HivemindSearched? theirs;
    if (!_stopAsked && position.hasMove(team.other)) {
      _set(analysis: AnalysisRunning(team.other));
      theirs = await _analyse(
        position,
        team.other,
        MustMove.either,
        1,
        generation,
      );
      if (theirs == null) return _resume(generation);
    }
    _set(analysis: _result(position, team, ours, theirs));
    await _resume(generation);
  }

  /// Ends the Analyze search early; what it found so far is kept.
  void stopAnalysis() {
    if (_analysis is! AnalysisRunning) return;
    _stopAsked = true;
    _engine?.stop();
  }

  /// One Analyze search; null when it is stale or failed, the failure shown.
  Future<HivemindSearched?> _analyse(
    TablePosition position,
    Team team,
    MustMove mustMove,
    int lines,
    int generation,
  ) async {
    final asked = await _search((
      position: position,
      team: team,
      maySit: lab.clock.maySit(team),
      mustMove: mustMove,
      lines: lines,
      budget: TimeBudget(lab.budget),
    ), generation);
    switch (asked) {
      case _Stale():
        return null;
      case _Troubled(:final trouble):
        _set(analysis: AnalysisFailed(trouble));
        return null;
      case _Answered(:final answer):
        return answer;
    }
  }

  AnalysisDone _result(
    TablePosition position,
    Team team,
    HivemindSearched ours,
    HivemindSearched? theirs,
  ) {
    final (:offset, :zero) = _offset({
      team: ours,
      team.other: ?theirs,
    }, lab.clock);
    final top = ours.top;
    final seen = <JointMove>{};
    final rows = [
      for (final line in ours.lines)
        if (line.pv.firstOrNull case final move? when seen.add(move))
          (move: move, score: TableScore.of(line, team, offset)),
    ];
    return AnalysisDone(
      position: position,
      team: team,
      advantage: top == null
          ? const TableScore()
          : TableScore.of(top, team, offset),
      zero: zero,
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

  /// After Analyze, the tables carry on where they left off.
  Future<void> _resume(int generation) async {
    if (_current(generation) && _scores is! ScoresFromBook) await _refresh();
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

  void _set({TableScores? scores, Analysis? analysis}) {
    if (_disposed) return;
    _scores = scores ?? _scores;
    _analysis = analysis ?? _analysis;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
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
