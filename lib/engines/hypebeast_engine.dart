import 'dart:async';

import '../chess/bughouse/hypebeast.dart';
import '../chess/bughouse/table.dart';
import '../diagnostics/log.dart';
import 'engine.dart';
import 'uci_process.dart';

/// How long a search may think: a node count, which replays the same way
/// every time, or a wall-clock time.
sealed class HypeBeastBudget {
  const HypeBeastBudget();

  String get go;

  /// How long the engine may say nothing new before it is taken for
  /// wedged: more nodes reported starts the wait again.
  Duration get patience;
}

final class NodeBudget extends HypeBeastBudget {
  const NodeBudget(this.nodes);

  final int nodes;

  @override
  String get go => 'go nodes $nodes';

  @override
  Duration get patience => const Duration(minutes: 10);
}

final class TimeBudget extends HypeBeastBudget {
  const TimeBudget(this.time);

  final Duration time;

  @override
  String get go => 'go movetime ${time.inMilliseconds}';

  /// Also the latest the answer may come, however busy the engine looks.
  @override
  Duration get patience => time + const Duration(minutes: 1);
}

/// One question for the engine: a table, the board to search for the side
/// to move there, how many lines to report, whether the coordinator looks
/// across to the partner board, the threads to search on and how long.
///
/// [played] is the table the game began on and the moves that led to
/// [position] (`1e2e4 2d7d5`), when moves alone led there. The engine is
/// then told the game rather than the position, which is how it knows a
/// position that came up before; null asks about the position alone.
///
/// [clocks], when the table has all four, are sent with it: the engine's
/// rules for sitting need them. Without them it never sits by those rules.
typedef HypeBeastQuestion = ({
  TablePosition position,
  ({TablePosition root, List<String> moves})? played,
  BoardNumber board,
  int lines,
  bool coordination,
  TableClocks? clocks,
  int threads,
  HypeBeastBudget budget,
});

sealed class HypeBeastAnswer {
  const HypeBeastAnswer();
}

/// What the seat chose — null when it had no move — and what the search
/// showed by the end.
final class HypeBeastSearched extends HypeBeastAnswer {
  const HypeBeastSearched({required this.decision, required this.report});

  final SeatDecision? decision;
  final SeatReport report;
}

final class HypeBeastFailed extends HypeBeastAnswer {
  const HypeBeastFailed(this.reason);

  /// A sentence for the user; the log has the detail.
  final String reason;
}

sealed class HypeBeastStart {
  const HypeBeastStart();
}

final class HypeBeastStarted extends HypeBeastStart {
  const HypeBeastStarted(this.engine);

  final HypeBeast engine;
}

final class HypeBeastStartFailed extends HypeBeastStart {
  const HypeBeastStartFailed(this.reason);

  /// A sentence for the user.
  final String reason;
}

/// What a search shows so far, each time it changes.
typedef HypeBeastReports = void Function(SeatReport report);

/// HypeBeast as the Bughouse mode uses it; a scripted engine in tests.
abstract interface class HypeBeast {
  /// Identity of the actual binary and net and the startup options.
  Map<String, Object?> get provenance;

  /// Whether a question with clocks was asked. The engine keeps the last
  /// clocks it was given — UCI cannot set its `Clocks` back to empty — so
  /// a question without clocks needs another process.
  bool get clocked;

  /// Searches [question], handing [onReport] what the search shows each
  /// time it changes. Questions are answered one at a time, in the order
  /// asked.
  Future<HypeBeastAnswer> search(
    HypeBeastQuestion question, {
    HypeBeastReports? onReport,
  });

  /// Cuts the search now running short; its answer still arrives, with
  /// what it found so far.
  void stop();

  Future<EngineExit> get exited;

  Future<void> quit();
}

/// The conversation with one HypeBeast process: Fairy-Stockfish's UCI with
/// the bughouse table as `position fen <board 1>|<board 2>`, moves with a
/// board digit in front (`1e2e4`), the seat options `Seat`, `Team` and
/// `Coordination`, and a joint answer, `bestmove (g8f6,pass)`. Its search
/// lines are the searched board's moves alone; [SeatReader] reads them.
///
/// The engine does not think after `bestmove`, so a search needs no `stop`
/// once answered; the process keeps its hash table between searches.
final class HypeBeastProcess implements HypeBeast, EngineProcess {
  HypeBeastProcess._(this._process) {
    _process.lines.listen(_onLine, onDone: _onExit);
  }

  /// Handshakes, loads [net] and applies [options], then proves the net
  /// loaded with a one-node search: Fairy-Stockfish says which net it
  /// evaluates with at the start of a search, prints `info string ERROR`
  /// and exits when the file does not load, and quietly falls back to its
  /// classical evaluation when the file's name does not start with the
  /// variant's. The last two throw an [EngineFailure] naming the net.
  ///
  /// An engine that says nothing by [patience], or exits without a word,
  /// is killed and the answer is null — the caller logs it, with what the
  /// engine wrote to stderr.
  static Future<HypeBeastProcess?> start(
    UciProcess process, {
    required String net,
    Map<String, String> options = const {},
    Map<String, Object?> provenance = const {},
    Duration patience = const Duration(seconds: 90),
  }) async {
    final engine = HypeBeastProcess._(process);
    engine._provenance.addAll({...provenance, 'options': options});
    try {
      engine._send('uci');
      await engine._expect('uciok').timeout(patience);
      engine
        .._set('HypeBeast', 'true')
        .._set('EvalFile', net);
      for (final MapEntry(:key, :value) in options.entries) {
        engine._set(key, value);
      }
      await engine._ready(patience);
      await engine._checkNet(patience);
      return engine;
    } on TimeoutException {
      await process.kill();
      return null;
    } on EngineFailure {
      await process.kill();
      if (engine._netProblem case final problem?) throw EngineFailure(problem);
      return null;
    }
  }

  final _provenance = <String, Object?>{};
  @override
  Map<String, Object?> get provenance => Map.unmodifiable(_provenance);

  final UciProcess _process;
  final _exited = Completer<EngineExit>();
  bool _unresponsive = false;
  Future<void> _queue = Future.value();

  /// Whether a search is under way, and whether it was asked to stop before
  /// its `go` went out.
  bool _searching = false;
  bool _cut = false;

  /// Each option's value as last sent, so an unchanged one is not sent.
  final _options = <String, String>{};

  @override
  bool get clocked => _options.containsKey('Clocks');
  ({String token, Completer<void> done})? _awaited;
  _Collecting? _collecting;

  /// While the net is being proved: whether the engine said it evaluates
  /// with it, and what it said instead.
  bool _checking = false;
  bool _netLoaded = false;
  String? _netProblem;

  @override
  int get pid => _process.pid;

  @override
  Future<EngineExit> get exited => _exited.future;

  @override
  Future<HypeBeastAnswer> search(
    HypeBeastQuestion question, {
    HypeBeastReports? onReport,
  }) {
    final answer = _queue.then((_) => _search(question, onReport));
    _queue = answer.then((_) {});
    return answer;
  }

  Future<HypeBeastAnswer> _search(
    HypeBeastQuestion question,
    HypeBeastReports? onReport,
  ) async {
    if (_exited.isCompleted || _unresponsive) {
      return const HypeBeastFailed(_gone);
    }
    _searching = true;
    _cut = false;
    try {
      await _configure(question);
      _send(switch (question.played) {
        (:final root, :final moves) when moves.isNotEmpty =>
          'position fen ${root.dualFen} moves ${moves.join(' ')}',
        _ => 'position fen ${question.position.dualFen}',
      });
      final collecting = _collecting = _Collecting(
        board: question.board,
        canMove: question.position.legalMoves(question.board).isNotEmpty,
        budget: question.budget,
        onReport: onReport,
      );
      _send(question.budget.go);
      if (_cut) _stopCollecting(collecting);
      return await collecting.done.future;
    } on TimeoutException {
      log.e('search on the bughouse engine', 'no bestmove; killed');
      _unresponsive = true;
      await _process.kill();
      return const HypeBeastFailed('The bughouse engine stopped answering.');
    } on EngineFailure catch (error) {
      log.e('search on the bughouse engine', error);
      return HypeBeastFailed(error.message);
    } finally {
      _collecting?.dispose();
      _collecting = null;
      _searching = false;
    }
  }

  /// Sends the seat's options that changed, then waits for `readyok`.
  ///
  /// With clocks, the engine first forgets the game it was in
  /// (`ucinewgame`): a hold, a wait or its timer belongs to one turn of one
  /// game, and the table asked about may be any other. That also empties
  /// its hash table (30–140 ms with 128 MB). Then the clocks, and whether
  /// the seat's team is ahead on time, which the engine also works out
  /// from the clocks and warns about when the two disagree.
  Future<void> _configure(HypeBeastQuestion question) async {
    final seat = seatOptions(question.position, question.board);
    if (question.clocks case final clocks?) {
      _send('ucinewgame');
      _set('Clocks', clocks.option);
      _set(
        'TimeAdvantage',
        '${clocks.ahead(question.position.mover(question.board).team)}',
      );
    }
    _set('Threads', '${question.threads < 1 ? 1 : question.threads}');
    _set('Seat', seat.seat);
    _set('Team', seat.team);
    _set('Coordination', '${question.coordination}');
    // The coordinator reports one line; alone, the board gets every line.
    _set(
      'MultiPV',
      '${question.coordination || question.lines < 1 ? 1 : question.lines}',
    );
    await _ready(const Duration(minutes: 1));
  }

  /// One node from the start, alone, to hear which net the engine reads.
  Future<void> _checkNet(Duration patience) async {
    _checking = true;
    try {
      _set('Coordination', 'false');
      _send('position startpos');
      _send('go nodes 1');
      await _expect('bestmove').timeout(patience);
    } finally {
      _checking = false;
    }
    if (!_netLoaded) {
      _netProblem ??= 'its net did not load.';
      throw EngineFailure(_netProblem!);
    }
  }

  void _set(String name, String value) {
    if (_options[name] == value) return;
    _options[name] = value;
    _send('setoption name $name value $value');
  }

  @override
  void stop() {
    if (!_searching || _cut) return;
    _cut = true;
    if (_collecting case final collecting?) _stopCollecting(collecting);
  }

  void _stopCollecting(_Collecting collecting) {
    collecting.stop();
    _send('stop');
  }

  @override
  Future<void> quit() async {
    if (_exited.isCompleted) return;
    _send('stop');
    _send('quit');
    await exited.timeout(
      const Duration(seconds: 5),
      onTimeout: () async {
        _unresponsive = true;
        await _process.kill();
        return EngineExit.unresponsive;
      },
    );
  }

  Future<void> _ready(Duration patience) {
    _send('isready');
    return _expect('readyok').timeout(patience);
  }

  /// Waits for the line [token]; for `bestmove`, any line that starts
  /// with it.
  Future<void> _expect(String token) {
    final done = Completer<void>();
    _awaited = (token: token, done: done);
    return done.future;
  }

  void _send(String line) => _process.send(line);

  void _onLine(String raw) {
    if (raw.startsWith('id name ')) {
      _provenance['engine_name'] = raw.substring(8).trim();
    }
    final line = raw.trim();
    if (_checking) _hearNet(line);
    final awaited = _awaited;
    if (awaited != null &&
        (line == awaited.token ||
            awaited.token == 'bestmove' && line.startsWith('bestmove'))) {
      _awaited = null;
      awaited.done.complete();
    } else if (line.startsWith('bestmove')) {
      _collecting?.finish(line);
    } else if (line.startsWith('info ')) {
      _collecting?.add(line);
    }
  }

  void _hearNet(String line) {
    if (line.startsWith('info string NNUE evaluation using ')) {
      _netLoaded = true;
      _provenance['net'] = line
          .substring('info string NNUE evaluation using '.length)
          .replaceFirst(RegExp(r'\s+enabled$'), '');
    } else if (line.startsWith('info string classical evaluation')) {
      _netProblem = 'its net was not taken for a bughouse net.';
    } else if (line.startsWith('info string ERROR')) {
      log.e('load the bughouse net', line.substring('info string '.length));
      _netProblem = 'its net did not load.';
    }
  }

  void _onExit() {
    const failure = EngineFailure(_gone);
    _awaited?.done.completeError(failure);
    _awaited = null;
    _collecting?.fail(failure);
    _exited.complete(
      _unresponsive ? EngineExit.unresponsive : EngineExit.ended,
    );
  }
}

const _gone = 'The bughouse engine stopped.';

/// The output of one search, read as it comes and handed on each time what
/// it shows changes; the answer is what it shows at `bestmove`.
final class _Collecting {
  _Collecting({
    required this.board,
    required this.canMove,
    required this.budget,
    this.onReport,
  }) {
    _watch(budget.patience);
    if (budget is TimeBudget) _deadline = Timer(budget.patience, _timedOut);
  }

  final BoardNumber board;

  /// Whether the side to move has a legal move on [board].
  final bool canMove;

  /// The search limit and how long it may make no progress before it is
  /// wedged.
  final HypeBeastBudget budget;
  final HypeBeastReports? onReport;
  final done = Completer<HypeBeastAnswer>();
  final _reader = SeatReader();
  Timer? _watchdog;
  Timer? _deadline;
  int _nodes = -1;
  bool _stopped = false;

  /// How long a stopped search may take to print `bestmove`; only a wedged
  /// engine runs past this.
  static const stopGrace = Duration(seconds: 30);

  void stop() {
    _stopped = true;
    _watch(stopGrace);
  }

  void add(String line) {
    if (!_reader.read(line)) return;
    final report = _reader.report;
    if (!_stopped && report.nodes > _nodes) {
      _nodes = report.nodes;
      _watch(budget.patience);
      if (budget case NodeBudget(:final nodes) when _nodes >= nodes) {
        _deadline ??= Timer(const Duration(minutes: 1), _timedOut);
      }
    }
    onReport?.call(report);
  }

  void _watch(Duration limit) {
    _watchdog?.cancel();
    _watchdog = Timer(limit, _timedOut);
  }

  void _timedOut() {
    if (!done.isCompleted) done.completeError(TimeoutException(null));
  }

  /// The answer at `bestmove`. An engine that reported an error
  /// (`info string hb_error …`, as for a move of the game it cannot play)
  /// answered something other than the question, and so did one that sits
  /// without searching a node where there are moves to make: both fail.
  void finish(String bestmove) {
    if (done.isCompleted) return;
    final report = _reader.report;
    final decision = parseBestMove(bestmove, board);
    if (report.error case final error?) {
      log.e('search on the bughouse engine', 'hb_error $error; $bestmove');
      done.complete(
        HypeBeastFailed(
          error.startsWith('position')
              ? 'The bughouse engine could not play the moves that led here.'
              : 'The bughouse engine reported an error.',
        ),
      );
    } else if (decision != null &&
        decision.sits &&
        report.nodes == 0 &&
        canMove) {
      log.e('search on the bughouse engine', 'sat without searching');
      done.complete(
        const HypeBeastFailed('The bughouse engine did not search the table.'),
      );
    } else {
      done.complete(HypeBeastSearched(decision: decision, report: report));
    }
  }

  void fail(EngineFailure failure) {
    if (!done.isCompleted) done.completeError(failure);
  }

  void dispose() {
    _watchdog?.cancel();
    _deadline?.cancel();
  }
}
