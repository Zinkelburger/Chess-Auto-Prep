import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartchess/dartchess.dart' hide File;

import '../models/bughouse_state.dart';

/// Thrown when the engine cannot be started or does not answer in time.
class BughouseEngineFailure implements Exception {
  BughouseEngineFailure(this.message);
  final String message;
  @override
  String toString() => 'BughouseEngineFailure: $message';
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
class BughouseEngine {
  BughouseEngine._(this._process, this.executablePath, this.modelPath) {
    _stdoutSub = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    _stderrSub = _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_stderrLines.add);
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

  bool _disposed = false;
  String _name = 'hivemind';
  String _backend = '';

  /// Engine name from `id name`.
  String get name => _name;

  /// Which inference backend the engine reported at load — "ONNX Runtime
  /// (CPU)" for the portable build, "TensorRT" when it found a GPU.
  String get backend => _backend;

  /// Live `info` lines for the search in progress.
  Stream<BughouseInfo> get infoStream => _infoController.stream;

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
    await isReady(timeout: timeout);
  }

  /// Which side the engine plays on board A, whether it is up on the diagonal
  /// clock, and whether it is forced to move on one board.
  ///
  /// Time advantage is not cosmetic: it decides whether sitting on both boards
  /// is legal at all. [requireMoveOn] goes further and forbids passing on the
  /// named board, which is the only way to ask "what if I simply have to move
  /// here" — the engine's clock model is otherwise a single bit, so "level"
  /// and "behind" are the same search to it.
  Future<void> configure({
    required Side team,
    required bool hasTimeAdvantage,
    RequireMoveOn requireMoveOn = RequireMoveOn.none,
    int multiPv = 1,
  }) async {
    _send(
      'setoption name Team value ${team == Side.white ? 'white' : 'black'}',
    );
    _send('setoption name TimeAdvantage value $hasTimeAdvantage');
    _send('setoption name RequireMoveOn value ${requireMoveOn.uciValue}');
    _send('setoption name MultiPV value ${multiPv < 1 ? 1 : multiPv}');
    await isReady();
  }

  Future<void> setOption(String name, Object value) async {
    _send('setoption name $name value $value');
    await isReady();
  }

  Future<void> newGame() async {
    _send('ucinewgame');
    await isReady();
  }

  Future<void> isReady({Duration timeout = const Duration(seconds: 60)}) async {
    _readyCompleter = Completer<void>();
    _send('isready');
    await _await(_readyCompleter!, timeout, 'isready');
  }

  /// Sets the two-board position. [moves] are joint half-moves already
  /// carrying their board prefix.
  Future<void> setPosition(
    BughouseState state, {
    List<String> moves = const [],
  }) async {
    final suffix = moves.isEmpty ? '' : ' moves ${moves.join(' ')}';
    _send('position fen ${state.dualFen}$suffix');
    await isReady();
  }

  /// Searches the current position and resolves when `bestmove` arrives.
  ///
  /// Exactly one of [movetime] / [nodes] should be given; with neither the
  /// engine defaults to one second.
  Future<BughouseSearchResult> search({
    Duration? movetime,
    int? nodes,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    if (_disposed) throw BughouseEngineFailure('Engine has been disposed');
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
  void stop() => _send('stop');

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
      // "info string backend ONNX Runtime (CPU) model ... batch 8 ..."
      final rest = text.substring('info string backend '.length);
      final modelAt = rest.indexOf(' model ');
      _backend = modelAt > 0 ? rest.substring(0, modelAt) : rest;
      return;
    }
    if (text.startsWith('bestmove')) {
      _onBestMove(text);
      return;
    }
    if (text.startsWith('info ') && text.contains(' depth ')) {
      final info = _parseInfo(text);
      if (info == null) return;
      _searchInfos?.add(info);
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
    return BughouseInfo(
      depth: depth,
      scoreCp: scoreCp,
      nodes: nodes,
      nps: nps,
      timeMs: timeMs,
      multipv: multipv,
      mateIn: mateIn,
      pv: pv,
    );
  }

  static String _at(List<String> tokens, int index) =>
      index >= 0 && index < tokens.length ? tokens[index] : '';
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
  List<BughouseInfo> get lines {
    final byRank = <int, BughouseInfo>{};
    for (final info in infos) {
      byRank[info.multipv] = info;
    }
    final ranks = byRank.keys.toList()..sort();
    return [for (final rank in ranks) byRank[rank]!];
  }

  /// The line the reported `bestmove` belongs to — rank 1, which the engine
  /// keeps aligned with its solver-aware choice.
  BughouseInfo? get principal {
    final ranked = lines;
    return ranked.isEmpty ? null : ranked.first;
  }
}
