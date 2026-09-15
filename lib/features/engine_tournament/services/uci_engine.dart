/// A UCI engine process driven for *play* rather than analysis.
///
/// The app's own `services/engine/` stack is built around evaluating a
/// position on demand and is wired to the bundled Stockfish. Tournament play
/// needs a different shape — an arbitrary binary, a clock in the `go`
/// command, a strict answer-or-forfeit contract, and a stable identity read
/// out of the handshake — so it gets its own driver rather than another mode
/// bolted onto [EvalWorker].
///
/// Pure `dart:io`: no Flutter imports, so `tools/run_engine_tournament.dart`
/// can drive the same code headlessly. The protocol vocabulary lives in
/// `uci_protocol.dart`; this file owns the process and the pipes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'uci_protocol.dart';
import 'uci_search_tracker.dart';

/// How long an engine is given to answer `stop` after overrunning its hard
/// limit before it is written off as hung.
const Duration _stopGrace = Duration(seconds: 5);

/// How long a `quit` is given before the process is killed.
const Duration _quitGrace = Duration(seconds: 2);

/// How long a killed process is given to go before SIGKILL.
const Duration _sigkillDelay = Duration(seconds: 2);

/// Stderr lines kept for the failure message.
const int _stderrLinesKept = 8;
const int _stderrLinesShown = 4;

class UciEngine implements PlayingEngine {
  UciEngine._(this._process, this.executablePath) {
    _stdoutSub = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: (Object e) => _die('stdout error: $e'));
    _stderrSub = _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (_stderr.length < _stderrLinesKept) _stderr.add(line);
          },
          onError: (Object _) {
            // Stderr is advisory; losing it must not fail the engine.
          },
        );
    unawaited(
      _process.exitCode.then((code) {
        if (_disposed) return;
        _die('process exited ($code)${_stderrSuffix()}');
      }),
    );
    // Writing to a dead engine fails asynchronously on the sink, not at the
    // `writeln` call, so a broken pipe reaches the zone as an unhandled
    // error unless it is caught here.
    unawaited(
      _process.stdin.done.then(
        (_) {},
        onError: (Object error) {
          if (_disposed) return;
          _die('engine stdin closed: $error');
        },
      ),
    );
  }

  final Process _process;
  final String executablePath;

  late final StreamSubscription<String> _stdoutSub;
  late final StreamSubscription<String> _stderrSub;
  final List<String> _stderr = [];

  final StreamController<String> _traffic =
      StreamController<String>.broadcast();

  Completer<UciIdentity>? _handshake;
  final List<Completer<void>> _readyQueue = [];
  _PendingSearch? _search;

  // Identity as it arrives during the handshake.
  final List<UciOptionInfo> _options = [];
  String _name = '';
  String _author = '';

  UciIdentity? _identity;
  bool _disposed = false;
  bool _dead = false;
  String? _deathReason;

  /// Every line the engine printed, for the log pane / verification report.
  Stream<String> get traffic => _traffic.stream;

  @override
  bool get isAlive => !_dead && !_disposed;

  UciIdentity? get identity => _identity;

  /// Start [executablePath]. Throws [UciFailure] if the process cannot be
  /// spawned at all (missing file, not executable, wrong architecture).
  static Future<UciEngine> launch({
    required String executablePath,
    List<String> arguments = const [],
    String? workingDirectory,
  }) async {
    final Process process;
    try {
      process = await Process.start(
        executablePath,
        arguments,
        workingDirectory: workingDirectory ?? p.dirname(executablePath),
      );
    } on ProcessException catch (e) {
      throw UciFailure('cannot start "$executablePath": ${e.message}');
    } catch (e) {
      throw UciFailure('cannot start "$executablePath": $e');
    }
    return UciEngine._(process, executablePath);
  }

  /// `uci` → `uciok`. The engine's name and its option list come back here.
  Future<UciIdentity> initialize({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    _requireAlive();
    final known = _identity;
    if (known != null) return known;
    final completer = Completer<UciIdentity>();
    _handshake = completer;
    _send('uci');
    final UciIdentity identity;
    try {
      identity = await completer.future.timeout(timeout);
    } on TimeoutException {
      _handshake = null;
      throw UciFailure(
        'no "uciok" within ${timeout.inSeconds}s — this does not look like a '
        'UCI engine${_stderrSuffix()}',
      );
    }
    _identity = identity;
    return identity;
  }

  Future<void> setOption(String name, String? value) async {
    _requireAlive();
    _send(
      value == null || value.isEmpty
          ? 'setoption name $name'
          : 'setoption name $name value $value',
    );
  }

  /// `isready` → `readyok`. Also the fence that guarantees every option sent
  /// before it has been applied.
  Future<void> isReady({Duration timeout = const Duration(seconds: 20)}) async {
    _requireAlive();
    final completer = Completer<void>();
    _readyQueue.add(completer);
    _send('isready');
    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      _readyQueue.remove(completer);
      throw UciFailure('no "readyok" within ${timeout.inSeconds}s');
    }
  }

  @override
  Future<void> newGame() async {
    _requireAlive();
    _send('ucinewgame');
    await isReady();
  }

  /// Set the position and search it. Returns when `bestmove` arrives.
  ///
  /// [hardLimit] is a hang guard, not the time control: it is deliberately
  /// looser than whatever [limits] asks for, and blowing it means the engine
  /// stopped answering rather than merely thought too long.
  @override
  Future<EngineSearch> search({
    required String startFen,
    required List<String> movesUci,
    required GoLimits limits,
    required Duration hardLimit,
  }) async {
    _requireAlive();
    final running = _search;
    if (running != null && !running.completer.isCompleted) {
      throw UciFailure('a search is already running');
    }

    final moves = movesUci.isEmpty ? '' : ' moves ${movesUci.join(' ')}';
    _send('position fen $startFen$moves');

    final pending = _PendingSearch();
    _search = pending;
    _send(limits.toCommand());

    try {
      return await pending.completer.future.timeout(hardLimit);
    } on TimeoutException {
      // Give it one chance to answer a `stop` before writing it off — an
      // engine that overshoots its budget is a forfeit, not a crash, and the
      // caller wants the move to tell them which.
      _send('stop');
      try {
        return await pending.completer.future.timeout(_stopGrace);
      } on TimeoutException {
        _search = null;
        _die('stopped responding after ${hardLimit.inSeconds}s');
        throw UciFailure(
          'no "bestmove" within ${hardLimit.inSeconds}s of "go"',
        );
      }
    }
  }

  @override
  Future<void> quit({Duration grace = _quitGrace}) async {
    if (_disposed) return;
    try {
      _send('quit');
      await _process.exitCode.timeout(grace);
    } catch (_) {
      // A wedged engine gets killed below.
    } finally {
      dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_stdoutSub.cancel());
    unawaited(_stderrSub.cancel());
    _failPending(UciFailure(_deathReason ?? 'engine disposed'));
    _kill();
    if (!Platform.isWindows) {
      Future.delayed(_sigkillDelay, () => _kill(ProcessSignal.sigkill));
    }
    unawaited(_traffic.close());
  }

  // ── internals ────────────────────────────────────────────────────────────

  void _kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    try {
      _process.kill(signal);
    } catch (_) {
      // Already gone.
    }
  }

  void _requireAlive() {
    if (_dead || _disposed) {
      throw UciFailure(_deathReason ?? 'engine is not running');
    }
  }

  void _send(String command) {
    if (_disposed) return;
    try {
      _process.stdin.writeln(command);
    } catch (e) {
      _die('cannot write to engine: $e');
    }
  }

  String _stderrSuffix() =>
      _stderr.isEmpty ? '' : '\n${_stderr.take(_stderrLinesShown).join('\n')}';

  void _die(String reason) {
    if (_dead) return;
    _dead = true;
    _deathReason = reason;
    _failPending(UciFailure(reason));
  }

  void _failPending(Object error) {
    final handshake = _handshake;
    _handshake = null;
    if (handshake != null && !handshake.isCompleted) {
      handshake.completeError(error);
    }
    final search = _search;
    _search = null;
    if (search != null && !search.completer.isCompleted) {
      search.completer.completeError(error);
    }
    final ready = List.of(_readyQueue);
    _readyQueue.clear();
    for (final c in ready) {
      if (!c.isCompleted) c.completeError(error);
    }
  }

  void _onLine(String raw) {
    final line = raw.trim();
    if (line.isEmpty) return;
    if (!_traffic.isClosed) _traffic.add(line);

    if (line == 'uciok') {
      _completeHandshake();
    } else if (line == 'readyok') {
      _completeReady();
    } else if (line.startsWith('id name ')) {
      _name = line.substring('id name '.length).trim();
    } else if (line.startsWith('id author ')) {
      _author = line.substring('id author '.length).trim();
    } else if (line.startsWith('option ')) {
      final option = UciOptionInfo.parse(line);
      if (option != null) _options.add(option);
    } else if (line.startsWith('bestmove')) {
      _completeSearch(line);
    } else if (line.startsWith('info ')) {
      _search?.tracker.observeInfo(line);
    }
  }

  void _completeHandshake() {
    final completer = _handshake;
    _handshake = null;
    completer?.complete(
      UciIdentity(
        name: _name.isEmpty ? _fallbackName() : _name,
        author: _author,
        options: List.unmodifiable(_options),
      ),
    );
  }

  void _completeReady() {
    if (_readyQueue.isEmpty) return;
    final completer = _readyQueue.removeAt(0);
    if (!completer.isCompleted) completer.complete();
  }

  void _completeSearch(String line) {
    final pending = _search;
    _search = null;
    if (pending == null || pending.completer.isCompleted) return;
    pending.completer.complete(pending.tracker.finish(line));
  }

  String _fallbackName() {
    final base = p.basename(executablePath);
    return base.isEmpty ? 'Engine' : base;
  }
}

/// A `go` that has not yet been answered.
class _PendingSearch {
  final Completer<EngineSearch> completer = Completer<EngineSearch>();
  final UciSearchTracker tracker = UciSearchTracker();
}
