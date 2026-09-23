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
  const ScoresFailed(this.reason);

  final String reason;
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
  const AnalysisFailed(this.reason);

  final String reason;
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
/// One engine answers both, one search at a time. A new position, clock or
/// question makes whatever the engine was doing stale: its search is cut
/// short and its answer dropped. Searches already made are remembered for
/// the session, so stepping back to a table searched before, or switching
/// back to a clock case, costs nothing.
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

  /// Which table the state above belongs to, to tell a new question from a
  /// hover or a flip.
  Object? _asked;
  bool _open = false;
  bool _disposed = false;

  /// Bumped by everything that makes the engine's work stale.
  int _generation = 0;

  Hivemind? _engine;
  Future<HivemindStart>? _starting;

  /// Why the engine would not start; the tables stop asking until Analyze
  /// is pressed again.
  String? _startFailure;
  bool _stopAsked = false;

  final _bookAnswers = <int, HivemindLookup>{};
  final _searches = <(int, Team, bool, int), HivemindSearched>{};

  TableScores get scores => _scores;
  Analysis get analysis => _analysis;

  /// Why the book could not be read, when it could not.
  String? get bookProblem => _bookProblem;

  /// Starts answering: the mode is on screen.
  void open() {
    _open = true;
    _asked = null;
    _labChanged();
  }

  /// Stops the engine's work: the mode is off screen. What was found stays.
  void close() {
    _open = false;
    _generation++;
    _engine?.stop();
  }

  void _labChanged() {
    final asked = (lab.position, lab.clock, lab.team, lab.mustMove, lab.budget);
    if (!_open || asked == _asked) return;
    _asked = asked;
    _analysis = const AnalysisIdle();
    unawaited(_refresh());
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
      _set(scores: ScoresFailed(reason));
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
    for (final team in teams) {
      final found = await _ask(position, team, clock, generation, own: true);
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
    for (final (board, uci) in candidates) {
      final played = position.play(board, uci)!;
      final answers = answering(position, board);
      final found = await _ask(played.after, answers, clock, generation);
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

  /// The search of [team] at [position] under [clock], from memory when it
  /// was made before; null when it is stale or failed, the failure shown.
  Future<HivemindSearched?> _ask(
    TablePosition position,
    Team team,
    ClockCase clock,
    int generation, {
    bool own = false,
  }) async {
    final maySit = clock.maySit(team);
    final nodes = own ? _depth.ownNodes : _depth.childNodes;
    final key = (position.bookKey, team, maySit, nodes);
    if (_searches[key] case final known?) return known;
    final engine = await _acquire();
    if (!_current(generation)) return null;
    if (engine == null) {
      _set(
        scores: ScoresFailed(
          _startFailure ?? 'The bughouse engine did not start.',
        ),
      );
      return null;
    }
    final answer = await engine.search((
      position: position,
      team: team,
      maySit: maySit,
      mustMove: MustMove.either,
      lines: own ? 8 : 1,
      budget: NodeBudget(nodes),
    ));
    if (!_current(generation)) return null;
    switch (answer) {
      case HivemindFailed(:final reason):
        _set(scores: ScoresFailed('Analysis failed: $reason'));
        return null;
      case final HivemindSearched found:
        return _searches[key] = found;
    }
  }

  /// Analyze: [BughouseLab.team]'s search for the Search chip's time, with
  /// its board that must be moved on, then the other team's for the zero.
  Future<void> analyze() async {
    if (!_open) return;
    final generation = ++_generation;
    _engine?.stop();
    _startFailure = null;
    _stopAsked = false;
    final position = lab.position;
    final team = lab.team;
    if (!position.hasMove(team)) {
      _set(analysis: AnalysisNoMove(team));
      return _resume(generation);
    }
    _set(analysis: AnalysisRunning(team));
    final ours = await _analyse(position, team, generation, own: true);
    if (ours == null) return;
    HivemindSearched? theirs;
    if (!_stopAsked && position.hasMove(team.other)) {
      _set(analysis: AnalysisRunning(team.other));
      theirs = await _analyse(position, team.other, generation);
      if (!_current(generation)) return;
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

  Future<HivemindSearched?> _analyse(
    TablePosition position,
    Team team,
    int generation, {
    bool own = false,
  }) async {
    final engine = await _acquire();
    if (!_current(generation)) return null;
    if (engine == null) {
      _set(
        analysis: AnalysisFailed(
          _startFailure ?? 'The bughouse engine did not start.',
        ),
      );
      return null;
    }
    final answer = await engine.search((
      position: position,
      team: team,
      maySit: lab.clock.maySit(team),
      mustMove: own ? lab.mustMove : MustMove.either,
      lines: own ? 3 : 1,
      budget: TimeBudget(lab.budget),
    ));
    if (!_current(generation)) return null;
    switch (answer) {
      case HivemindFailed(:final reason):
        _set(analysis: AnalysisFailed('Analysis failed: $reason'));
        return null;
      case final HivemindSearched found:
        return found;
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
        if (_disposed) {
          unawaited(engine.quit());
          return null;
        }
        _engine = engine;
        unawaited(engine.exited.then((_) => _lost(engine)));
        return engine;
    }
  }

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
