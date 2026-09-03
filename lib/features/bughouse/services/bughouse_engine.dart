import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartchess/dartchess.dart' hide File;

import '../models/bughouse_engine_settings.dart';
import '../models/bughouse_state.dart';

/// Thrown when the engine cannot be started or does not answer in time.
class BughouseEngineFailure implements Exception {
  BughouseEngineFailure(this.message);
  final String message;
  @override
  String toString() => 'BughouseEngineFailure: $message';
}

/// What a caller needs from a bughouse engine, without a process behind it.
///
/// [BughouseEngine] is the real implementation and starts Hivemind; this
/// interface exists so the controller's analysis loop — which is where all the
/// hard parts live (a pump that alternates teams, generation invalidation,
/// scenario comparison) — can be driven by a scripted fake in tests. Without
/// it the only injectable engine was a real 54 MB process, which is why none
/// of that code had any coverage.
abstract class BughouseAnalysisEngine {
  /// Which inference backend the engine reported at load.
  String get backend;

  /// How that backend is running: workers, intra-op threads and the inference
  /// batch, as the engine itself reported them.
  ///
  /// This is the answer to "how many cores does it use", and it is a readout
  /// rather than a control because Hivemind does not advertise a `Threads`
  /// option — see [BughouseEngineSettings]. It is re-reported whenever
  /// `BatchSize` changes, so it stays true after a settings change.
  String get backendDetail;

  /// Sets one UCI option and waits for the engine to acknowledge it.
  Future<void> setOption(String name, Object value);

  /// False once the process has exited, however it exited.
  bool get isAlive;

  /// Live `info` lines for the search in progress.
  Stream<BughouseInfo> get infoStream;

  Future<void> configure({
    required Side team,
    required bool hasTimeAdvantage,
    RequireMoveOn requireMoveOn,
    int multiPv,
  });

  Future<void> setPosition(BughouseState state, {List<String> moves});

  /// Runs one search.
  ///
  /// Implementations must cross a real event-loop turn — process I/O, or a
  /// timer in a fake. The analysis pump calls this in a loop, so an
  /// implementation that answered purely from microtasks would keep the
  /// microtask queue non-empty forever and starve every timer in the isolate,
  /// including the ones that would have stopped it.
  Future<BughouseSearchResult> search({
    Duration? movetime,
    int? nodes,
    Duration timeout,
  });

  /// Interrupts a running search; `bestmove` still follows.
  void stop();

  Future<void> dispose();
}

/// A client for Hivemind, the neural-network bughouse engine.
///
/// It speaks UCI, but not the UCI a chess GUI expects: bughouse needs two
/// boards, so the dialect differs in three ways that this class hides.
///
///   * `position fen <boardA>|<boardB>` — two crazyhouse FENs, pipe-separated.
///   * Moves carry a board digit: `1e2e4` is e2e4 on board A, `2d7d5` on B.
///   * `bestmove (d2d4,pass)` — a *joint* action, one half per board, where
///     `pass` (deliberately not moving) is a legal and often correct choice.
///
/// `go` is asynchronous and the engine keeps thinking in a permanent-brain
/// loop afterwards, so callers must wait for `bestmove` rather than firing
/// commands back to back — sending `quit` straight after `go` aborts the
/// search before a single node is expanded.
///
/// One process answers one question at a time, and this class is what enforces
/// that: every public method queues on [_serialise]. The completers below hold
/// a single waiter each, so two callers overlapping would hand one of them the
/// other's `readyok` or `bestmove` — and there are three callers (the analysis
/// pump, the scenario comparison, and the pause button), which is too many to
/// keep in step by convention.
class BughouseEngine implements BughouseAnalysisEngine {
  BughouseEngine._(this._process, this.executablePath, this.modelPath) {
    _stdoutSub = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    _stderrSub = _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_stderrLines.add);
    // A crashed engine used to be invisible: nothing failed the pending
    // completer, so the next search waited out its full ten-minute timeout and
    // `_engine` kept handing back the corpse.
    unawaited(
      _process.exitCode.then((code) {
        _exited = true;
        if (!_disposed) _failPending('Engine exited ($code)');
      }),
    );
  }

  final Process _process;
  final String executablePath;
  final String modelPath;

  late final StreamSubscription<String> _stdoutSub;
  late final StreamSubscription<String> _stderrSub;

  final List<String> _stderrLines = [];
  final _infoController = StreamController<BughouseInfo>.broadcast();

  Completer<void>? _readyCompleter;
  Completer<void>? _uciOkCompleter;
  Completer<_SearchResult>? _searchCompleter;

  /// Where `info` lines land while a search is running. Null between searches.
  List<BughouseInfo>? _searchInfos;

  /// How many `info` lines one search keeps. Generous — a 30-second pass emits
  /// a couple of dozen — but bounded, because nothing else bounds it.
  static const int _maxInfos = 512;

  bool _disposed = false;
  bool _exited = false;
  String _name = 'hivemind';
  String _backend = '';
  String _backendDetail = '';

  /// The `TimeAdvantage` the current search was configured with. Stamped onto
  /// every parsed line, because it decides which baseline that line's score is
  /// measured against — see [BughouseInfo.levelBaselineFor].
  bool _timeAdvantage = false;

  /// Serialises every command: one process answers one question at a time.
  Future<void> _queue = Future<void>.value();

  /// Engine name from `id name`.
  String get name => _name;

  /// Which inference backend the engine reported at load — "ONNX Runtime
  /// (CPU)" for the portable build, "TensorRT" when it found a GPU.
  @override
  String get backend => _backend;

  @override
  String get backendDetail => _backendDetail;

  @override
  bool get isAlive => !_exited && !_disposed;

  /// Live `info` lines for the search in progress.
  @override
  Stream<BughouseInfo> get infoStream => _infoController.stream;

  /// Runs [body] after every command already queued, so two callers cannot
  /// interleave `setoption`/`position`/`go` on one stdin or race for the
  /// single-slot completers. A failure does not poison the queue.
  Future<T> _serialise<T>(Future<T> Function() body) {
    final result = _queue.then((_) => body());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Everything the engine wrote to stderr, for surfacing load failures
  /// (a missing model, an FP16 network) instead of a bare timeout.
  List<String> get diagnostics => List.unmodifiable(_stderrLines);

  static Future<BughouseEngine> launch({
    required String executablePath,
    required String modelPath,

    /// Directory holding libonnxruntime. The bundled binary is built with an
    /// RPATH from the build machine, so the runtime has to be found by
    /// environment instead of by embedded path.
    String? libraryPath,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (!await File(executablePath).exists()) {
      throw BughouseEngineFailure('Engine binary not found: $executablePath');
    }
    if (!await File(modelPath).exists()) {
      throw BughouseEngineFailure('Network not found: $modelPath');
    }

    final environment = <String, String>{};
    if (libraryPath != null) {
      final key = Platform.isMacOS ? 'DYLD_LIBRARY_PATH' : 'LD_LIBRARY_PATH';
      final existing = Platform.environment[key];
      environment[key] = existing == null || existing.isEmpty
          ? libraryPath
          : '$libraryPath:$existing';
    }

    final Process process;
    try {
      process = await Process.start(
        executablePath,
        ['--model', modelPath],
        environment: environment.isEmpty ? null : environment,
        includeParentEnvironment: true,
      );
    } on ProcessException catch (e) {
      throw BughouseEngineFailure('Could not start the engine: ${e.message}');
    }

    final engine = BughouseEngine._(process, executablePath, modelPath);
    try {
      await engine._handshake(timeout);
    } catch (_) {
      await engine.dispose();
      rethrow;
    }
    return engine;
  }

  Future<void> _handshake(Duration timeout) async {
    _uciOkCompleter = Completer<void>();
    _send('uci');
    await _await(_uciOkCompleter!, timeout, 'uci');
    await _isReady(timeout: timeout);
  }

  /// Which side the engine plays on board A, whether it is up on the diagonal
  /// clock, and whether it is forced to move on one board.
  ///
  /// Time advantage is not cosmetic: it decides whether sitting on both boards
  /// is legal at all. [requireMoveOn] goes further and forbids passing on the
  /// named board, which is the only way to ask "what if I simply have to move
  /// here" — the engine's clock model is otherwise a single bit, so "level"
  /// and "behind" are the same search to it.
  @override
  Future<void> configure({
    required Side team,
    required bool hasTimeAdvantage,
    RequireMoveOn requireMoveOn = RequireMoveOn.none,
    int multiPv = 1,
  }) => _serialise(() async {
    _send(
      'setoption name Team value ${team == Side.white ? 'white' : 'black'}',
    );
    _timeAdvantage = hasTimeAdvantage;
    _send('setoption name TimeAdvantage value $hasTimeAdvantage');
    _send('setoption name RequireMoveOn value ${requireMoveOn.uciValue}');
    _send('setoption name MultiPV value ${multiPv < 1 ? 1 : multiPv}');
    await _isReady();
  });

  @override
  Future<void> setOption(String name, Object value) => _serialise(() async {
    _send('setoption name $name value $value');
    await _isReady();
  });

  Future<void> newGame() => _serialise(() async {
    _send('ucinewgame');
    await _isReady();
  });

  Future<void> isReady({Duration timeout = const Duration(seconds: 60)}) =>
      _serialise(() => _isReady(timeout: timeout));

  /// The round-trip itself, already inside the queue.
  Future<void> _isReady({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    _readyCompleter = Completer<void>();
    _send('isready');
    await _await(_readyCompleter!, timeout, 'isready');
  }

  /// Sets the two-board position. [moves] are joint half-moves already
  /// carrying their board prefix.
  @override
  Future<void> setPosition(
    BughouseState state, {
    List<String> moves = const [],
  }) => _serialise(() async {
    final suffix = moves.isEmpty ? '' : ' moves ${moves.join(' ')}';
    _send('position fen ${state.dualFen}$suffix');
    await _isReady();
  });

  /// Searches the current position and resolves when `bestmove` arrives.
  ///
  /// Exactly one of [movetime] / [nodes] should be given; with neither the
  /// engine defaults to one second.
  @override
  Future<BughouseSearchResult> search({
    Duration? movetime,
    int? nodes,
    Duration timeout = const Duration(minutes: 10),
  }) => _serialise(() => _search(movetime, nodes, timeout));

  Future<BughouseSearchResult> _search(
    Duration? movetime,
    int? nodes,
    Duration timeout,
  ) async {
    if (_disposed) throw BughouseEngineFailure('Engine has been disposed');
    if (_exited) {
      throw BughouseEngineFailure(
        'Engine is not running.${_stderrLines.isEmpty ? '' : '\n${_stderrLines.take(8).join('\n')}'}',
      );
    }
    _searchCompleter = Completer<_SearchResult>();
    // Collected as the lines are read, not through [infoStream]: a broadcast
    // stream delivers asynchronously, so the engine's final MultiPV block —
    // printed immediately before `bestmove` — loses the race with the
    // completer and the shortlist arrives empty.
    final infos = _searchInfos = <BughouseInfo>[];

    if (nodes != null) {
      _send('go nodes $nodes');
    } else if (movetime != null) {
      _send('go movetime ${movetime.inMilliseconds}');
    } else {
      _send('go');
    }

    try {
      final result = await _await(_searchCompleter!, timeout, 'go');
      return BughouseSearchResult(
        best: result.best,
        ponder: result.ponder,
        infos: List.unmodifiable(infos),
      );
    } finally {
      _searchInfos = null;
      // Left alone the engine keeps a permanent-brain search on every core
      // between calls, starving the next one.
      _send('stop');
    }
  }

  /// Interrupts a running search; `bestmove` still follows.
  ///
  /// Deliberately *not* serialised: its whole job is to cut short a command
  /// that is already at the head of the queue.
  @override
  void stop() => _send('stop');

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      _send('stop');
      _send('quit');
      await _process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {
      _process.kill(ProcessSignal.sigkill);
    }
    await _stdoutSub.cancel();
    await _stderrSub.cancel();
    await _infoController.close();
    _failPending('Engine stopped');
  }

  // ---------------------------------------------------------------- internals

  void _send(String command) {
    try {
      _process.stdin.writeln(command);
    } catch (_) {
      // The process died; pending waiters time out or fail below.
    }
  }

  Future<T> _await<T>(Completer<T> completer, Duration timeout, String what) {
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        final why = _stderrLines.isEmpty
            ? ''
            : '\n${_stderrLines.take(8).join('\n')}';
        throw BughouseEngineFailure(
          'Engine did not answer "$what" within ${timeout.inSeconds}s$why',
        );
      },
    );
  }

  void _failPending(String message) {
    for (final c in [_readyCompleter, _uciOkCompleter]) {
      if (c != null && !c.isCompleted) {
        c.completeError(BughouseEngineFailure(message));
      }
    }
    final search = _searchCompleter;
    if (search != null && !search.isCompleted) {
      search.completeError(BughouseEngineFailure(message));
    }
  }

  void _onLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return;

    if (text == 'uciok') {
      _completeOnce(_uciOkCompleter);
      return;
    }
    if (text == 'readyok') {
      _completeOnce(_readyCompleter);
      return;
    }
    if (text.startsWith('id name ')) {
      _name = text.substring('id name '.length).trim();
      return;
    }
    if (text.startsWith('info string backend ')) {
      // "info string backend ONNX Runtime (CPU) model hivemind.onnx batch 8
      //  workers 4 intra-op threads 5"
      final rest = text.substring('info string backend '.length);
      final modelAt = rest.indexOf(' model ');
      _backend = modelAt > 0 ? rest.substring(0, modelAt) : rest;
      _backendDetail = _summariseBackend(rest);
      return;
    }
    if (text.startsWith('bestmove')) {
      _onBestMove(text);
      return;
    }
    if (text.startsWith('info ') && text.contains(' depth ')) {
      final info = _parseInfo(text);
      if (info == null) return;
      final collected = _searchInfos;
      if (collected != null) {
        collected.add(info);
        // Only the tail matters — `lines` keeps the last state of each rank,
        // and the engine prints its MultiPV block immediately before
        // `bestmove`. A ten-minute timeout is the real ceiling otherwise.
        if (collected.length > _maxInfos) {
          collected.removeRange(0, collected.length - _maxInfos);
        }
      }
      if (!_infoController.isClosed) _infoController.add(info);
    }
  }

  void _completeOnce(Completer<void>? completer) {
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _onBestMove(String text) {
    final completer = _searchCompleter;
    if (completer == null || completer.isCompleted) return;

    // bestmove (d2d4,pass) ponder (d7d5,d2d4)
    final ponderAt = text.indexOf(' ponder ');
    final bestPart = ponderAt >= 0
        ? text.substring('bestmove '.length, ponderAt)
        : text.substring('bestmove '.length);
    final ponderPart = ponderAt >= 0
        ? text.substring(ponderAt + ' ponder '.length)
        : null;

    completer.complete(
      _SearchResult(
        BughouseJointMove.tryParse(bestPart),
        ponderPart == null ? null : BughouseJointMove.tryParse(ponderPart),
      ),
    );
  }

  BughouseInfo? _parseInfo(String text) {
    final tokens = text.split(RegExp(r'\s+'));
    int depth = 0, nodes = 0, nps = 0, timeMs = 0, scoreCp = 0, multipv = 1;
    int? mateIn;
    final pv = <BughouseJointMove>[];

    for (var i = 0; i < tokens.length; i++) {
      switch (tokens[i]) {
        case 'depth':
          depth = int.tryParse(_at(tokens, i + 1)) ?? depth;
        case 'multipv':
          multipv = int.tryParse(_at(tokens, i + 1)) ?? multipv;
        case 'nodes':
          nodes = int.tryParse(_at(tokens, i + 1)) ?? nodes;
        case 'nps':
          nps = int.tryParse(_at(tokens, i + 1)) ?? nps;
        case 'time':
          timeMs = int.tryParse(_at(tokens, i + 1)) ?? timeMs;
        case 'score':
          // "score cp -230" or "score mate 3"
          switch (_at(tokens, i + 1)) {
            case 'cp':
              scoreCp = int.tryParse(_at(tokens, i + 2)) ?? scoreCp;
            case 'mate':
              mateIn = int.tryParse(_at(tokens, i + 2));
          }
        case 'pv':
          for (final token in tokens.sublist(i + 1)) {
            final move = BughouseJointMove.tryParse(token);
            if (move != null) pv.add(move);
          }
          i = tokens.length;
      }
    }
    if (depth == 0 && pv.isEmpty) return null;
    // The root's unvisited MCTS prior, Q = -1, which the engine prints as
    // `180*tan(-1.56)` = -16671 on the first line of every single search
    // before any node has been evaluated. Folded into the live eval it made
    // the headline number flash -164.41 and empty the bar at the start of
    // every pass. A node count, not the magic value, is what says "nothing has
    // actually been looked at yet".
    if (nodes <= 1) return null;
    return BughouseInfo(
      depth: depth,
      scoreCp: scoreCp,
      nodes: nodes,
      nps: nps,
      timeMs: timeMs,
      multipv: multipv,
      mateIn: mateIn,
      hadTimeAdvantage: _timeAdvantage,
      pv: pv,
    );
  }

  static String _at(List<String> tokens, int index) =>
      index >= 0 && index < tokens.length ? tokens[index] : '';

  /// `4 workers · 5 threads · batch 8` out of the engine's own backend line.
  ///
  /// Each part is optional: a build that stops reporting one of them should
  /// shorten the readout, not print a zero.
  static String _summariseBackend(String rest) {
    final parts = <String>[
      if (_numberAfter(rest, 'workers ') case final n?) '$n workers',
      if (_numberAfter(rest, 'intra-op threads ') case final n?) '$n threads',
      if (_numberAfter(rest, 'batch ') case final n?) 'batch $n',
    ];
    return parts.join(' · ');
  }

  static final _leadingDigits = RegExp(r'^\d+');

  static int? _numberAfter(String text, String key) {
    final at = text.indexOf(key);
    if (at < 0) return null;
    final match = _leadingDigits.firstMatch(text.substring(at + key.length));
    return match == null ? null : int.tryParse(match[0]!);
  }
}

class _SearchResult {
  _SearchResult(this.best, this.ponder);
  final BughouseJointMove? best;
  final BughouseJointMove? ponder;
}

/// What one completed search produced.
class BughouseSearchResult {
  const BughouseSearchResult({
    required this.best,
    required this.ponder,
    required this.infos,
  });

  final BughouseJointMove? best;
  final BughouseJointMove? ponder;
  final List<BughouseInfo> infos;

  BughouseInfo? get lastInfo => infos.isEmpty ? null : infos.last;

  /// The final state of each ranked line, best first.
  ///
  /// The engine re-emits every rank on each deepening, so what matters is the
  /// last `info` seen per `multipv` index — anything earlier is a stale view
  /// of the same line.
  ///
  /// Sorted by score rather than left in the engine's own MultiPV order, which
  /// is an MCTS *visit* count: measured on a real block, ranks 1-5 scored
  /// +0.08, -0.61, -0.38, -0.46, -0.53, so presenting that order as a ranking
  /// contradicts the numbers printed beside it. Rank 1 stays pinned at the
  /// front because it is the line `bestmove` is aligned with — the engine's
  /// solver-aware choice, which is not always its highest score.
  List<BughouseInfo> get lines {
    final byRank = <int, BughouseInfo>{};
    for (final info in infos) {
      byRank[info.multipv] = info;
    }
    final ranks = byRank.keys.toList()..sort();
    final ordered = [for (final rank in ranks) byRank[rank]!];
    if (ordered.length < 2) return ordered;
    final rest = ordered.sublist(1)
      ..sort((a, b) => _strength(b).compareTo(_strength(a)));
    return [ordered.first, ...rest];
  }

  /// How good a line is for the team that was searched. Higher is better; a
  /// mate for us beats every score, a mate against us loses to every score,
  /// and inside each group the faster mate is the more extreme one.
  static double _strength(BughouseInfo info) {
    final mate = info.mateIn;
    if (mate == null) return info.scoreCp.toDouble();
    const huge = 1000000.0;
    return mate > 0 ? huge - mate : -huge - mate;
  }

  /// The line the reported `bestmove` belongs to — rank 1, which the engine
  /// keeps aligned with its solver-aware choice.
  BughouseInfo? get principal {
    final ranked = lines;
    return ranked.isEmpty ? null : ranked.first;
  }
}
