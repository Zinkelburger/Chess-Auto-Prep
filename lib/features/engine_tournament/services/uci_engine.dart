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
/// can drive the same code headlessly.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Anything that makes an engine unusable: it would not start, would not
/// speak UCI, went silent, or died.
class UciFailure implements Exception {
  UciFailure(this.message);
  final String message;
  @override
  String toString() => 'UciFailure: $message';
}

/// One `option name … type …` line from the handshake.
class UciOptionInfo {
  const UciOptionInfo({
    required this.name,
    required this.type,
    this.defaultValue,
    this.min,
    this.max,
    this.values = const [],
  });

  final String name;
  final String type;
  final String? defaultValue;
  final String? min;
  final String? max;
  final List<String> values;
}

/// What an engine says about itself before the first move.
class UciIdentity {
  const UciIdentity({
    required this.name,
    required this.author,
    required this.options,
  });

  final String name;
  final String author;
  final List<UciOptionInfo> options;

  bool supportsOption(String name) =>
      options.any((o) => o.name.toLowerCase() == name.toLowerCase());
}

/// The limits half of a `go` command.
class GoLimits {
  const GoLimits({
    this.whiteTimeMs,
    this.blackTimeMs,
    this.whiteIncrementMs,
    this.blackIncrementMs,
    this.movesToGo,
    this.movetimeMs,
    this.depth,
    this.nodes,
  });

  final int? whiteTimeMs;
  final int? blackTimeMs;
  final int? whiteIncrementMs;
  final int? blackIncrementMs;
  final int? movesToGo;
  final int? movetimeMs;
  final int? depth;
  final int? nodes;

  String toCommand() {
    final parts = <String>['go'];
    void add(String key, int? value) {
      if (value != null) parts.addAll([key, '$value']);
    }

    add('wtime', whiteTimeMs);
    add('btime', blackTimeMs);
    add('winc', whiteIncrementMs);
    add('binc', blackIncrementMs);
    add('movestogo', movesToGo);
    add('movetime', movetimeMs);
    add('depth', depth);
    add('nodes', nodes);
    if (parts.length == 1) parts.add('infinite');
    return parts.join(' ');
  }
}

/// The engine's answer to one `go`.
class EngineSearch {
  const EngineSearch({
    required this.bestMoveUci,
    required this.elapsedMs,
    this.ponderUci,
    this.scoreCp,
    this.scoreMate,
    this.depth = 0,
    this.nodes,
  });

  /// UCI move string, or `(none)` / `0000` when the engine sees no move.
  final String bestMoveUci;

  final String? ponderUci;

  /// Last reported score, in the **side-to-move** perspective UCI defines.
  final int? scoreCp;
  final int? scoreMate;

  final int depth;
  final int? nodes;
  final int elapsedMs;

  bool get hasMove =>
      bestMoveUci.isNotEmpty &&
      bestMoveUci != '(none)' &&
      bestMoveUci != '0000' &&
      bestMoveUci != 'null';

  /// Mate scores collapsed onto the centipawn axis so adjudication can
  /// compare them with ordinary evaluations. A mate in 1 must outrank any
  /// finite advantage, and a longer mate must outrank a shorter one from the
  /// losing side's view.
  int? get comparableCp {
    if (scoreMate != null) {
      final n = scoreMate!;
      // `mate 0` is UCI for "the side to move is mated" — a loss, and
      // emphatically not the level score a plain zero would read as.
      if (n == 0) return -30000;
      final magnitude = 30000 - n.abs();
      return n > 0 ? magnitude : -magnitude;
    }
    return scoreCp;
  }
}

/// What the game runner needs from a competitor.
///
/// Narrower than [UciEngine] on purpose: the arbiter only ever asks for a
/// move, and an interface this small is what lets the game loop be tested
/// against scripted engines instead of real processes.
abstract interface class PlayingEngine {
  bool get isAlive;

  /// Tell the engine a new game is starting and wait for it to be ready.
  Future<void> newGame();

  Future<EngineSearch> search({
    required String startFen,
    required List<String> movesUci,
    required GoLimits limits,
    required Duration hardLimit,
  });

  /// Ask it to exit, then make sure it has.
  Future<void> quit();

  /// Stop it now, without waiting.
  void dispose();
}

class UciEngine implements PlayingEngine {
  UciEngine._(this._process, this.executablePath) {
    _stdoutSub = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: (Object e) => _die('stdout error: $e'));
    _stderrSub = _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (_stderr.length < 8) _stderr.add(line);
        }, onError: (Object _) {});
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
  Completer<EngineSearch>? _search;

  final List<UciOptionInfo> _options = [];
  String _name = '';
  String _author = '';

  UciIdentity? _identity;
  bool _disposed = false;
  bool _dead = false;
  String? _deathReason;

  // Accumulated `info` state for the search in flight.
  int? _scoreCp;
  int? _scoreMate;
  int _depth = 0;
  int? _nodes;
  Stopwatch? _searchClock;

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
        workingDirectory: workingDirectory ?? File(executablePath).parent.path,
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
    if (_identity != null) return _identity!;
    final completer = Completer<UciIdentity>();
    _handshake = completer;
    _send('uci');
    try {
      _identity = await completer.future.timeout(timeout);
    } on TimeoutException {
      _handshake = null;
      throw UciFailure(
        'no "uciok" within ${timeout.inSeconds}s — this does not look like a '
        'UCI engine${_stderrSuffix()}',
      );
    }
    return _identity!;
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
    if (_search != null && !_search!.isCompleted) {
      throw UciFailure('a search is already running');
    }

    _scoreCp = null;
    _scoreMate = null;
    _depth = 0;
    _nodes = null;

    final moves = movesUci.isEmpty ? '' : ' moves ${movesUci.join(' ')}';
    _send('position fen $startFen$moves');

    final completer = Completer<EngineSearch>();
    _search = completer;
    _searchClock = Stopwatch()..start();
    _send(limits.toCommand());

    try {
      return await completer.future.timeout(hardLimit);
    } on TimeoutException {
      // Give it one chance to answer a `stop` before writing it off — an
      // engine that overshoots its budget is a forfeit, not a crash, and the
      // caller wants the move to tell them which.
      _send('stop');
      try {
        return await completer.future.timeout(const Duration(seconds: 5));
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
  Future<void> quit({Duration grace = const Duration(seconds: 2)}) async {
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
    try {
      _process.kill();
    } catch (_) {
      /* already gone */
    }
    if (!Platform.isWindows) {
      Future.delayed(const Duration(seconds: 2), () {
        try {
          _process.kill(ProcessSignal.sigkill);
        } catch (_) {
          /* already gone */
        }
      });
    }
    unawaited(_traffic.close());
  }

  // ── internals ────────────────────────────────────────────────────────────

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
      _stderr.isEmpty ? '' : '\n${_stderr.take(4).join('\n')}';

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
    if (search != null && !search.isCompleted) search.completeError(error);
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
      final completer = _handshake;
      _handshake = null;
      completer?.complete(
        UciIdentity(
          name: _name.isEmpty ? _fallbackName() : _name,
          author: _author,
          options: List.unmodifiable(_options),
        ),
      );
      return;
    }
    if (line == 'readyok') {
      if (_readyQueue.isNotEmpty) {
        final c = _readyQueue.removeAt(0);
        if (!c.isCompleted) c.complete();
      }
      return;
    }
    if (line.startsWith('id ')) {
      _parseId(line);
      return;
    }
    if (line.startsWith('option ')) {
      final option = _parseOption(line);
      if (option != null) _options.add(option);
      return;
    }
    if (line.startsWith('bestmove')) {
      _completeSearch(line);
      return;
    }
    if (line.startsWith('info ')) {
      _parseInfo(line);
    }
  }

  String _fallbackName() {
    final base = executablePath.split(Platform.pathSeparator).last;
    return base.isEmpty ? 'Engine' : base;
  }

  void _parseId(String line) {
    if (line.startsWith('id name ')) {
      _name = line.substring('id name '.length).trim();
    } else if (line.startsWith('id author ')) {
      _author = line.substring('id author '.length).trim();
    }
  }

  static const _optionKeywords = {
    'name',
    'type',
    'default',
    'min',
    'max',
    'var',
  };

  UciOptionInfo? _parseOption(String line) {
    // `option name Foo Bar type spin default 1 min 0 max 8` — names contain
    // spaces, so the fields are split on keywords rather than whitespace.
    final tokens = line.split(RegExp(r'\s+')).skip(1).toList();
    final fields = <String, List<String>>{};
    String? key;
    for (final token in tokens) {
      if (_optionKeywords.contains(token)) {
        key = token;
        if (token == 'var') {
          fields.putIfAbsent('var', () => []).add('');
        } else {
          fields[token] = [];
        }
        continue;
      }
      if (key == null) continue;
      if (key == 'var') {
        final list = fields['var']!;
        list[list.length - 1] = '${list.last} $token'.trim();
      } else {
        fields[key]!.add(token);
      }
    }
    final name = fields['name']?.join(' ').trim();
    if (name == null || name.isEmpty) return null;
    return UciOptionInfo(
      name: name,
      type: fields['type']?.join(' ').trim() ?? 'string',
      defaultValue: fields['default']?.join(' ').trim(),
      min: fields['min']?.join(' ').trim(),
      max: fields['max']?.join(' ').trim(),
      values: fields['var']?.where((v) => v.isNotEmpty).toList() ?? const [],
    );
  }

  void _parseInfo(String line) {
    // `info string …` is chatter, and its words collide with real keys.
    if (line.startsWith('info string')) return;
    final parts = line.split(RegExp(r'\s+'));
    // Only the principal variation matters for the played move; a MultiPV
    // engine's lower lines would otherwise overwrite the best score.
    for (var i = 0; i < parts.length - 1; i++) {
      if (parts[i] == 'multipv' && parts[i + 1] != '1') return;
    }
    for (var i = 0; i < parts.length; i++) {
      switch (parts[i]) {
        case 'depth':
          if (i + 1 < parts.length) {
            _depth = int.tryParse(parts[i + 1]) ?? _depth;
          }
        case 'nodes':
          if (i + 1 < parts.length) {
            _nodes = int.tryParse(parts[i + 1]) ?? _nodes;
          }
        case 'score':
          if (i + 2 < parts.length) {
            final value = int.tryParse(parts[i + 2]);
            if (value != null) {
              if (parts[i + 1] == 'cp') {
                _scoreCp = value;
                _scoreMate = null;
              } else if (parts[i + 1] == 'mate') {
                _scoreMate = value;
                _scoreCp = null;
              }
            }
          }
        case 'pv':
          return;
      }
    }
  }

  void _completeSearch(String line) {
    final completer = _search;
    _search = null;
    if (completer == null || completer.isCompleted) return;
    final parts = line.split(RegExp(r'\s+'));
    final best = parts.length > 1 ? parts[1] : '';
    String? ponder;
    final ponderIndex = parts.indexOf('ponder');
    if (ponderIndex >= 0 && ponderIndex + 1 < parts.length) {
      ponder = parts[ponderIndex + 1];
    }
    final clock = _searchClock;
    _searchClock = null;
    completer.complete(
      EngineSearch(
        bestMoveUci: best,
        ponderUci: ponder,
        scoreCp: _scoreCp,
        scoreMate: _scoreMate,
        depth: _depth,
        nodes: _nodes,
        elapsedMs: clock?.elapsedMilliseconds ?? 0,
      ),
    );
  }
}
