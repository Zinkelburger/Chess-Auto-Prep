import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../chess/bughouse/hypebeast.dart';
import '../../chess/bughouse/table.dart';
import '../../diagnostics/log.dart';
import '../../engines/hypebeast_engine.dart';
import '../../workspace/latest.dart';
import 'bughouse_lab.dart';

/// What the engine switch shows.
sealed class LabLines {
  const LabLines();
}

final class LinesOff extends LabLines {
  const LinesOff();
}

/// On, over [position] as [boards] shows it: each board's rows for the
/// player on move there as the engine has them now — none before its first
/// report — the score, and whether the engine is still searching.
final class LinesOn extends LabLines {
  const LinesOn({
    required this.position,
    required this.boards,
    this.rows = const {},
    this.score = const TableScore(),
    this.nodes,
    this.thinking = true,
    this.progress,
  });

  final TablePosition position;
  final LabBoards boards;
  final Map<BoardNumber, List<EngineRow>> rows;

  /// A + B's score: with one board, its first row's; with two, both
  /// boards' first rows added (a mate on either is the score).
  final TableScore score;

  /// The size of the searches the rows come from, both boards' together;
  /// null before there are rows.
  final int? nodes;
  final bool thinking;

  /// How much of the search time has gone, 0 to 1; null before it starts.
  final double? progress;
}

/// The engine is on but could not answer; it stays off until switched on
/// again.
final class LinesStopped extends LabLines {
  const LinesStopped(this.reason);

  /// A sentence for the user.
  final String reason;
}

/// One of a board's rows: the move as UCI — null when the player would
/// rather sit there — A + B's score for it (empty when the engine did not
/// score it), that board's line from [table], the table it was searched
/// on, and how far it falls behind the board's first row, 0 to 1, for the
/// width of its arrow (1 for a row without a score).
typedef EngineRow = ({
  String? move,
  TableScore score,
  List<String> pv,
  TablePosition table,
  double shift,
});

/// How long each search runs before it rests until the table changes: the
/// website's default.
const labSearchTime = Duration(seconds: 10);

/// Rows shown per board.
const labLineCount = 3;

/// HypeBeast over the table on screen while its switch is on.
///
/// One board: board 1 is searched for its side to move, on its own, with
/// [labLineCount] lines; the partner board is passed as the table has it.
/// Two boards: each board with a legal move is searched for its side to
/// move, on its own engine process, with the coordinator looking across to
/// the partner board. The game that led to the table is sent with it, so
/// the engine knows a position that came up before.
///
/// Each search runs for [labSearchTime], shown as it reports, and rests
/// until the table changes. The engine processes share the machine's cores
/// but one. A new position, board count or switch makes whatever the
/// engines were doing stale: their searches are cut short and their
/// answers dropped. Finished searches are remembered for the session. The
/// engines are quit when the mode is left and started again on return.
final class LabEngine extends ChangeNotifier {
  LabEngine({
    required this.lab,
    required this._startEngine,
    required this.cores,
    this.searchTime = labSearchTime,
  }) {
    lab.addListener(_labChanged);
  }

  final BughouseLab lab;
  final Future<HypeBeastStart> Function() _startEngine;

  /// The cores the app's engines may use; one is left for the app.
  final int cores;
  final Duration searchTime;

  LabLines _lines = const LinesOff();
  bool _on = false;
  bool _open = false;
  bool _disposed = false;

  /// What the lines were last asked for; a hover or a flip changes nothing.
  (TablePosition, LabBoards)? _asked;

  /// The engine's runs: everything that makes its work stale overtakes
  /// the one under way.
  final _runs = Latest();

  /// The engine processes, one per board searched at once.
  final _engines = <HypeBeast?>[null, null];
  final _starting = <Future<HypeBeastStart>?>[null, null];

  /// The search each engine is on, which its next one waits for.
  final _busy = <Future<void>>[Future.value(), Future.value()];

  final _searches = <_SearchKey, _Found>{};

  /// Moves the progress line on while a search runs.
  Timer? _ticker;

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
    _cancelRuns();
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

  void _cancelRuns() {
    _runs.cancel();
    _ticker?.cancel();
    _ticker = null;
  }

  /// The engine switch: on, the engine runs over the table on screen; off,
  /// whatever it was doing is cut short.
  void toggle() {
    _on = !_on;
    _asked = null;
    if (_on) {
      _labChanged();
    } else {
      _cancelRuns();
      _stopAll();
      _set(const LinesOff());
    }
  }

  void _labChanged() {
    if (!_on || !_open) return;
    final asked = (lab.position, lab.boards);
    if (asked == _asked) return;
    _asked = asked;
    _cancelRuns();
    final run = _runs.begin();
    _stopAll();
    _set(LinesOn(position: lab.position, boards: lab.boards));
    unawaited(_analyse(run, asked));
  }

  Future<void> _analyse(Ticket run, (TablePosition, LabBoards) asked) async {
    final (position, boards) = asked;
    bool wanted() => _on && _open && run.current;
    final questions = boards == LabBoards.one
        ? _oneBoard(position)
        : _twoBoards(position);
    if (questions.isEmpty) {
      _set(LinesOn(position: position, boards: boards, thinking: false));
      return;
    }
    final threads = math.max(1, (cores - 1) ~/ questions.length);
    final found = <BoardNumber, _Found>{};
    final clock = Stopwatch()..start();
    void show() {
      if (!wanted()) return;
      final thinking =
          found.values.where((f) => f.done).length < questions.length;
      if (!thinking) {
        _ticker?.cancel();
        _ticker = null;
      }
      final rows = {
        for (final question in questions)
          if (found[question.board] case final f?)
            question.board: _rows(position, question, f),
      };
      _set(
        LinesOn(
          position: position,
          boards: boards,
          rows: rows,
          score: _score(rows),
          nodes: found.isEmpty
              ? null
              : found.values.fold<int>(0, (sum, f) => sum + f.report.nodes),
          thinking: thinking,
          progress: thinking
              ? (clock.elapsedMilliseconds / searchTime.inMilliseconds).clamp(
                  0.0,
                  1.0,
                )
              : 1.0,
        ),
      );
    }

    final searching = <_Question>[];
    for (final question in questions) {
      if (_searches[_key(question, boards)] case final known?) {
        found[question.board] = known;
      } else {
        searching.add(question);
      }
    }
    show();
    if (searching.isEmpty) return;
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) => show());
    await Future.wait([
      for (final (seat, question) in searching.indexed)
        _stream(seat, question, threads, wanted, (f) {
          found[question.board] = f;
          if (f.done) _remember(_key(question, boards), f);
          show();
        }),
    ]);
  }

  /// [question] searched on engine [seat], every report handed to
  /// [update]; the finished search last.
  Future<void> _stream(
    int seat,
    _Question question,
    int threads,
    bool Function() wanted,
    void Function(_Found found) update,
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
      _toAsk(question, threads),
      onReport: (report) {
        if (wanted()) update((report: report, decision: null, done: false));
      },
    );
    _busy[seat] = searching.then((_) {}, onError: (Object _) {});
    final answer = await searching;
    if (!wanted()) return;
    switch (answer) {
      case HypeBeastFailed(:final reason):
        _stopped('Analysis failed: $reason');
      case HypeBeastSearched(:final report, :final decision):
        update((report: report, decision: decision, done: true));
    }
  }

  /// Board 1 for its side to move, alone, with every line shown.
  List<_Question> _oneBoard(TablePosition position) => [
    if (position.legalMoves(BoardNumber.one).isNotEmpty)
      (
        table: position,
        played: _played(position),
        board: BoardNumber.one,
        coordinated: false,
      ),
  ];

  /// Each board with a move to make, for its side to move, coordinated.
  List<_Question> _twoBoards(TablePosition position) => [
    for (final board in BoardNumber.values)
      if (position.legalMoves(board).isNotEmpty)
        (
          table: position,
          played: _played(position),
          board: board,
          coordinated: true,
        ),
  ];

  /// The game that led to [position], when it is the table on screen and
  /// moves alone led to it: the engine then sees a repeated position as one.
  ({TablePosition root, List<String> moves})? _played(TablePosition position) {
    final moves = position == lab.position ? lab.line.engineMoves : null;
    return moves == null ? null : (root: lab.line.root, moves: moves);
  }

  HypeBeastQuestion _toAsk(_Question question, int threads) => (
    position: question.table,
    played: question.played,
    board: question.board,
    lines: question.coordinated ? 1 : labLineCount,
    coordination: question.coordinated,
    threads: threads,
    budget: TimeBudget(searchTime),
  );

  void _remember(_SearchKey key, _Found found) {
    if (_searches.length > _rememberedSearches) _searches.clear();
    _searches[key] = found;
  }

  static _SearchKey _key(_Question question, LabBoards boards) => (
    question.table.dualFen,
    // The same table reached another way is another search.
    question.played?.moves.join(' '),
    boards,
    question.board,
  );

  /// [found]'s rows for [question]'s board, A + B's side.
  List<EngineRow> _rows(
    TablePosition position,
    _Question question,
    _Found found,
  ) {
    final rows = seatRows(
      found.report,
      coordinated: question.coordinated,
      decision: found.done ? found.decision : null,
      count: labLineCount,
    );
    final team = position.mover(question.board).team;
    final shifts = rowShifts(rows);
    return [
      for (final (i, row) in rows.indexed)
        (
          move: row.move,
          score: TableScore.forSeat(cp: row.cp, mate: row.mate, team: team),
          pv: row.pv,
          table: question.table,
          shift: shifts[i],
        ),
    ];
  }

  /// A + B's score: one board's first row, or both boards' added.
  TableScore _score(Map<BoardNumber, List<EngineRow>> rows) => TableScore.sum([
    for (final board in rows.values) ?board.firstOrNull?.score,
  ]);

  /// The rows on screen for [board], when they are for the table shown.
  List<EngineRow> rowsOn(BoardNumber board) => switch (_lines) {
    LinesOn(:final position, :final boards, :final rows)
        when position == lab.position && boards == lab.boards =>
      rows[board] ?? const [],
    _ => const [],
  };

  /// The first row's move on [board] played there; nothing when it would
  /// sit or has not reported.
  void playBest(BoardNumber board) {
    if (rowsOn(board).firstOrNull?.move case final uci?) lab.play(board, uci);
  }

  String? _startFailure;

  /// Engine [seat], started the first time it is needed and again after
  /// it went away; null when it will not start.
  Future<HypeBeast?> _acquire(int seat) async {
    final running = _engines[seat];
    if (running != null) return running;
    final starting = _starting[seat] ??= _startEngine();
    final start = await starting;
    if (identical(_starting[seat], starting)) _starting[seat] = null;
    switch (start) {
      case HypeBeastStartFailed(:final reason):
        _startFailure = reason;
        return null;
      case HypeBeastStarted(:final engine):
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
  void _lost(int seat, HypeBeast engine) {
    if (identical(_engines[seat], engine)) _engines[seat] = null;
  }

  /// An engine could not answer: the switch goes off and says why.
  void _stopped(String reason) {
    _on = false;
    _cancelRuns();
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
    _runs.close();
    _ticker?.cancel();
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

typedef _SearchKey = (String, String?, LabBoards, BoardNumber);

/// What a board's search has shown, its decision, and whether it ended.
typedef _Found = ({SeatReport report, SeatDecision? decision, bool done});

/// One board's search.
typedef _Question = ({
  TablePosition table,
  ({TablePosition root, List<String> moves})? played,
  BoardNumber board,
  bool coordinated,
});
