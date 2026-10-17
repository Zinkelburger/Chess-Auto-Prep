import 'dart:async';

import '../chess/bughouse/hivemind.dart';
import '../chess/bughouse/table.dart';
import '../diagnostics/log.dart';
import 'engine.dart';
import 'uci_process.dart';

/// How long a search may think: a node count, which replays the same way
/// every time, or a wall-clock time.
sealed class HivemindBudget {
  const HivemindBudget();

  String get go;

  /// How long the engine may say nothing before it is taken for wedged:
  /// every `info` line it prints starts the wait again.
  Duration get patience;
}

final class NodeBudget extends HivemindBudget {
  const NodeBudget(this.nodes);

  final int nodes;

  @override
  String get go => 'go nodes $nodes';

  @override
  Duration get patience => const Duration(minutes: 10);
}

final class TimeBudget extends HivemindBudget {
  const TimeBudget(this.time);

  final Duration time;

  @override
  String get go => 'go movetime ${time.inMilliseconds}';

  @override
  Duration get patience => time + const Duration(minutes: 1);
}

/// One question for the engine: a table, the team whose move is wanted,
/// whether that team may sit, a board it may not sit on, how many ranked
/// lines to report and how long to think.
typedef HivemindQuestion = ({
  TablePosition position,
  Team team,
  bool maySit,
  MustMove mustMove,
  int lines,
  HivemindBudget budget,
});

sealed class HivemindAnswer {
  const HivemindAnswer();
}

/// The joint action the engine chose — null when the team had no move —
/// and its ranked lines, rank 1 first (the line `bestmove` follows), the
/// rest best-scoring first.
final class HivemindSearched extends HivemindAnswer {
  const HivemindSearched({required this.best, required this.lines});

  final JointMove? best;
  final List<JointLine> lines;

  JointLine? get top => lines.firstOrNull;
}

final class HivemindFailed extends HivemindAnswer {
  const HivemindFailed(this.reason);

  /// A sentence for the user; the log has the detail.
  final String reason;
}

sealed class HivemindStart {
  const HivemindStart();
}

final class HivemindStarted extends HivemindStart {
  const HivemindStarted(this.engine);

  final Hivemind engine;
}

final class HivemindStartFailed extends HivemindStart {
  const HivemindStartFailed(this.reason);

  /// A sentence for the user.
  final String reason;
}

/// The lines a search has so far, rank 1 first as [rankedLines] orders
/// them; their `nodes` is the size of the search when they were printed.
typedef HivemindLines = void Function(List<JointLine> lines);

/// Hivemind as the Bughouse mode uses it; a scripted engine in tests.
abstract interface class Hivemind {
  /// Identity of the actual binary/network and effective startup options.
  Map<String, Object?> get provenance;

  /// Whether the engine prints its lines while it searches. A build
  /// without it (an unpatched engine) says nothing until `bestmove`, so
  /// [search] never calls its `onLines`.
  bool get streams;

  /// Searches [question], handing [onLines] each block of lines the engine
  /// prints along the way (a few times a second when it [streams]).
  /// Questions are answered one at a time, in the order asked.
  Future<HivemindAnswer> search(
    HivemindQuestion question, {
    HivemindLines? onLines,
  });

  /// Cuts the search now running short; its answer still arrives, with
  /// what it found so far.
  void stop();

  Future<EngineExit> get exited;

  Future<void> quit();
}

/// The conversation with one Hivemind process. It speaks UCI with three
/// differences, all read here: `position fen <board 1>|<board 2>`, moves
/// with a board digit inside a joint action — `bestmove (d2d4,pass)` — and
/// the options `Team`, `TimeAdvantage` and `RequireMoveOn`.
///
/// After `bestmove` the engine goes on thinking in the background, so every
/// search is followed by a `stop`, or the next one would share the cores
/// with it.
///
/// A build carrying `tools/bughouse_windows/live-search.patch` offers the
/// option `ReportIntervalMs` and prints its whole MultiPV block every 250 ms
/// while it searches; that is what [streams] reads.
final class HivemindProcess implements Hivemind, EngineProcess {
  HivemindProcess._(this._process) {
    _process.lines.listen(_onLine, onDone: _onExit);
  }

  /// Handshakes and applies [options]. Loading the network takes seconds, so
  /// the handshake gets [patience]; an engine that says nothing by then, or
  /// exits first, is killed and the answer is null — the caller logs it,
  /// with what the engine wrote to stderr.
  static Future<HivemindProcess?> start(
    UciProcess process, {
    Map<String, String> options = const {},
    Map<String, Object?> provenance = const {},
    Duration patience = const Duration(seconds: 90),
  }) async {
    final engine = HivemindProcess._(process);
    engine._provenance.addAll({...provenance, 'options': options});
    try {
      engine._send('uci');
      await engine._expect('uciok').timeout(patience);
      for (final MapEntry(:key, :value) in options.entries) {
        engine._send('setoption name $key value $value');
      }
      await engine._ready(patience);
      return engine;
    } on TimeoutException {
      await process.kill();
      return null;
    } on EngineFailure {
      await process.kill();
      return null;
    }
  }

  final _provenance = <String, Object?>{};
  @override
  Map<String, Object?> get provenance => Map.unmodifiable(_provenance);

  bool _streams = false;
  @override
  bool get streams => _streams;

  final UciProcess _process;
  final _exited = Completer<EngineExit>();
  bool _unresponsive = false;
  Future<void> _queue = Future.value();

  /// Whether a search is under way, and whether it was asked to stop before
  /// its `go` went out.
  bool _searching = false;
  bool _cut = false;

  /// The options the last search set, so an unchanged one is not sent.
  String? _configured;
  ({String token, Completer<void> done})? _awaited;
  _Collecting? _collecting;

  @override
  int get pid => _process.pid;

  @override
  Future<EngineExit> get exited => _exited.future;

  @override
  Future<HivemindAnswer> search(
    HivemindQuestion question, {
    HivemindLines? onLines,
  }) {
    final answer = _queue.then((_) => _search(question, onLines));
    _queue = answer.then((_) {});
    return answer;
  }

  Future<HivemindAnswer> _search(
    HivemindQuestion question,
    HivemindLines? onLines,
  ) async {
    if (_exited.isCompleted) return const HivemindFailed(_gone);
    _searching = true;
    _cut = false;
    try {
      await _configure(question);
      _send('position fen ${question.position.dualFen}');
      final collecting = _collecting = _Collecting(
        wanted: question.lines,
        patience: question.budget.patience,
        onLines: onLines,
      );
      _send(question.budget.go);
      if (_cut) _send('stop');
      final answer = await collecting.done.future;
      _send('stop');
      return answer;
    } on TimeoutException {
      log.e('search on the bughouse engine', 'no bestmove; killed');
      _unresponsive = true;
      await _process.kill();
      return const HivemindFailed('The bughouse engine stopped answering.');
    } on EngineFailure catch (error) {
      log.e('search on the bughouse engine', error);
      return HivemindFailed(error.message);
    } finally {
      _collecting?.dispose();
      _collecting = null;
      _searching = false;
    }
  }

  /// Sends the options that changed, then waits for `readyok` whatever
  /// changed: the engine goes on thinking after `bestmove` until the `stop`
  /// that follows it, and anything it prints before `readyok` belongs to
  /// the search before, which must not land in this one.
  Future<void> _configure(HivemindQuestion question) async {
    final options = [
      'Team value ${engineTeam(question.team)}',
      'TimeAdvantage value ${question.maySit}',
      'RequireMoveOn value ${question.mustMove.engineValue}',
      'MultiPV value ${question.lines < 1 ? 1 : question.lines}',
    ];
    final key = options.join('|');
    if (key != _configured) {
      for (final option in options) {
        _send('setoption name $option');
      }
    }
    await _ready(const Duration(minutes: 1));
    _configured = key;
  }

  @override
  void stop() {
    if (!_searching) return;
    _cut = true;
    if (_collecting != null) _send('stop');
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

  Future<void> _expect(String token) {
    final done = Completer<void>();
    _awaited = (token: token, done: done);
    return done.future;
  }

  void _send(String line) => _process.send(line);

  void _onLine(String raw) {
    if (raw.startsWith('id name ')) {
      _provenance['engine_name'] = raw.substring(8).trim();
    } else if (raw.startsWith('option name ReportIntervalMs ')) {
      _streams = true;
      _provenance['streams'] = true;
    }
    final line = raw.trim();
    final awaited = _awaited;
    if (awaited != null && line == awaited.token) {
      _awaited = null;
      awaited.done.complete();
    } else if (line.startsWith('bestmove')) {
      _collecting?.finish(line);
    } else if (parseHivemindInfo(line) case final info?) {
      _collecting?.add(info);
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

/// The `info` lines of one search. The engine prints a block of up to
/// [wanted] ranks at a time, rank 1 first; each rank 1 starts a new block,
/// and a block is handed on when its last rank arrives or the next block
/// starts. The answer holds the last block, which the engine prints just
/// before `bestmove`.
final class _Collecting {
  _Collecting({required this.wanted, required this.patience, this.onLines}) {
    _watch();
  }

  final int wanted;

  /// How long the engine may print nothing before it is taken for wedged.
  final Duration patience;
  final HivemindLines? onLines;
  final done = Completer<HivemindAnswer>();
  var _block = <int, JointLine>{};
  bool _handed = false;
  Timer? _watchdog;

  void add(JointLine line) {
    _watch();
    if (line.rank == 1) {
      _hand();
      _block = {};
      _handed = false;
    }
    _block[line.rank] = line;
    if (line.rank >= wanted) _hand();
  }

  void _hand() {
    if (_handed || _block.isEmpty) return;
    _handed = true;
    onLines?.call(rankedLines(_block.values));
  }

  void _watch() {
    _watchdog?.cancel();
    _watchdog = Timer(patience, () {
      if (!done.isCompleted) done.completeError(TimeoutException(null));
    });
  }

  void finish(String bestmove) {
    if (done.isCompleted) return;
    done.complete(
      HivemindSearched(
        best: parseBestMove(bestmove),
        lines: rankedLines(_block.values),
      ),
    );
  }

  void fail(EngineFailure failure) {
    if (!done.isCompleted) done.completeError(failure);
  }

  void dispose() => _watchdog?.cancel();
}

/// `bestmove (d2d4,pass) ponder (d7d5,d2d4)` → the chosen action; null for
/// `bestmove (none)`, which is what a team with no move gets.
JointMove? parseBestMove(String line) {
  final fields = line.split(RegExp(r'\s+'));
  return fields.length < 2 ? null : JointMove.parse(fields[1]);
}

/// One search `info` line, or null when it carries nothing to read: an
/// `info string`, or the root's first line before any node was evaluated,
/// which prints the unvisited prior as a huge negative score.
JointLine? parseHivemindInfo(String line) {
  if (!line.startsWith('info ') || !line.contains(' depth ')) return null;
  final tokens = line.split(RegExp(r'\s+'));
  int number(String key) {
    final at = tokens.indexOf(key);
    return at < 0 || at + 1 >= tokens.length
        ? 0
        : int.tryParse(tokens[at + 1]) ?? 0;
  }

  final nodes = number('nodes');
  if (nodes <= 1) return null;
  final score = tokens.indexOf('score');
  final kind = score < 0 || score + 2 >= tokens.length
      ? null
      : tokens[score + 1];
  final value = kind == null ? null : int.tryParse(tokens[score + 2]);
  final pv = tokens.indexOf('pv');
  return JointLine(
    rank: number('multipv') == 0 ? 1 : number('multipv'),
    cp: kind == 'cp' ? value : null,
    mate: kind == 'mate' ? value : null,
    nodes: nodes,
    depth: number('depth'),
    pv: [
      if (pv >= 0)
        for (final token in tokens.skip(pv + 1)) ?JointMove.parse(token),
    ],
  );
}
