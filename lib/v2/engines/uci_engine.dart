import 'dart:async';

import '../chess/fen.dart';
import '../diagnostics/log.dart';
import 'engine.dart';
import 'engine_line.dart';
import 'uci_process.dart';

/// The UCI conversation with one engine process.
///
/// Searches are serialised: a new one waits for the previous `bestmove`
/// before sending `go`, and `info` lines go to whichever search the engine
/// is on. That is what keeps a stale evaluation off the board. The wait is
/// bounded: an engine that answers neither `bestmove` nor anything else is
/// killed rather than waited on.
final class UciEngine implements Engine, EngineProcess {
  UciEngine._(this._process) {
    _process.lines.listen(_onLine, onDone: _onExit);
  }

  /// Handshakes and applies [options]. Throws [TimeoutException] when the
  /// process does not answer within [patience] and [EngineFailure] when it
  /// exits first.
  static Future<UciEngine> start(
    UciProcess process, {
    Map<String, String> options = const {},
    Duration patience = const Duration(seconds: 10),
  }) async {
    final engine = UciEngine._(process);
    engine._send('uci');
    await engine._expect('uciok').timeout(patience);
    for (final MapEntry(:key, :value) in options.entries) {
      engine._send('setoption name $key value $value');
    }
    engine._send('isready');
    await engine._expect('readyok').timeout(patience);
    return engine;
  }

  final UciProcess _process;
  final _exited = Completer<EngineExit>();
  String _name = 'UCI engine';

  /// Set when we kill the engine for saying nothing, so its exit says why.
  bool _unresponsive = false;

  /// The handshake token being waited for and who to wake when it lands.
  ({String token, Completer<void> completer})? _awaited;

  /// The search the engine is on; `info` lines go here.
  _UciSearch? _current;

  /// The search most recently asked for, which the next one waits behind.
  _UciSearch? _latest;
  Future<void> _turn = Future.value();

  @override
  String get name => _name;

  @override
  int get pid => _process.pid;

  @override
  Future<EngineExit> get exited => _exited.future;

  @override
  Search analyse(Fen fen, {required int multiPv, int? depth}) {
    final search = _UciSearch(_send, finite: depth != null);
    final previous = _latest;
    _latest = search;
    // One search that fails must not break the queue: without this, a
    // single error would leave every later `analyse` waiting on a rejected
    // future and no `go` would ever be sent again.
    _turn = _turn
        .then((_) => _begin(search, previous, fen, multiPv, depth))
        .catchError((Object error) {
          log.w('start a search on $_name', error);
          search.finish();
        });
    return search.public;
  }

  Future<void> _begin(
    _UciSearch search,
    _UciSearch? previous,
    Fen fen,
    int multiPv,
    int? depth,
  ) async {
    if (previous != null && !await _stopped(previous)) return search.finish();
    if (_exited.isCompleted) return search.finish();
    if (search.isDone) return; // stopped before it began
    _current = search;
    _send('setoption name MultiPV value $multiPv');
    _send('position fen ${fen.value}');
    _send(depth == null ? 'go infinite' : 'go depth $depth');
    search.markRunning();
  }

  /// Whether [previous] really stopped, waiting as long as an engine that is
  /// working can take to answer `stop` with `bestmove`.
  ///
  /// One that answers neither would otherwise hold every later search behind
  /// it for as long as the process lives, leaving the pane on a position the
  /// board has left. It is killed instead, and its exit says it was
  /// [EngineExit.unresponsive], which is what tells the workspace to start
  /// another engine rather than give up on the session.
  ///
  /// A fixed-depth search is waited for, not stopped: it ends on its own,
  /// and its verdict is what its caller is holding out for. One that takes
  /// longer than any depth an engine is asked for here should is killed on
  /// the same terms.
  Future<bool> _stopped(_UciSearch previous) async {
    try {
      if (previous.finite && previous.isRunning) {
        await previous.done.timeout(_finitePatience);
      } else {
        await previous.stop().timeout(_stopPatience);
      }
      return true;
    } on TimeoutException {
      log.e(
        'stop a search on $_name',
        const EngineFailure('the engine did not answer stop'),
      );
      _unresponsive = true;
      await _process.kill();
      return false;
    }
  }

  @override
  Future<void> quit() async {
    if (_exited.isCompleted) return;
    _send('quit');
    await exited.timeout(
      const Duration(seconds: 2),
      onTimeout: () async {
        await _process.kill();
        // We asked it to go, so a slow goodbye is not a broken engine.
        return EngineExit.ended;
      },
    );
  }

  void _send(String line) => _process.send(line);

  Future<void> _expect(String token) {
    final completer = Completer<void>();
    _awaited = (token: token, completer: completer);
    return completer.future;
  }

  void _onLine(String line) {
    final awaited = _awaited;
    if (awaited != null && line == awaited.token) {
      _awaited = null;
      awaited.completer.complete();
    } else if (line.startsWith('id name ')) {
      _name = line.substring('id name '.length);
    } else if (line.startsWith('bestmove')) {
      _current?.finish();
      _current = null;
    } else if (parseInfoLine(line) case final info?) {
      _current?.add(info);
    }
  }

  void _onExit() {
    _awaited?.completer.completeError(const EngineFailure('engine exited'));
    _awaited = null;
    _current?.finish();
    _current = null;
    _exited.complete(
      _unresponsive ? EngineExit.unresponsive : EngineExit.ended,
    );
  }
}

/// How long a search that has been told to stop may take to say `bestmove`.
/// Stockfish answers within milliseconds; seconds of silence mean the engine
/// is not coming back.
const _stopPatience = Duration(seconds: 5);

/// How long a fixed-depth search may run before the engine is taken for
/// wedged. The depths asked for here finish in well under a second; a
/// minute of silence is a process that is not coming back.
const _finitePatience = Duration(minutes: 1);

/// A search as the engine sees it: queued, running, or finished once
/// `bestmove` arrived.
final class _UciSearch {
  _UciSearch(this._send, {required this.finite});

  final void Function(String line) _send;

  /// Ends on its own at a depth, rather than when it is stopped.
  final bool finite;
  final _lines = StreamController<EngineLine>();
  final _done = Completer<void>();
  bool _running = false;
  bool _stopSent = false;
  late final public = Search(lines: _lines.stream, stop: stop);

  bool get isDone => _done.isCompleted;

  bool get isRunning => _running && !isDone;

  Future<void> get done => _done.future;

  void markRunning() => _running = true;

  void add(EngineLine line) => _lines.add(line);

  /// Queued: cancelled outright. Running: one `stop`, then wait for the
  /// engine's `bestmove`, which is when it has really stopped.
  Future<void> stop() {
    if (isDone) return _done.future;
    if (!_running) {
      finish();
    } else if (!_stopSent) {
      _stopSent = true;
      _send('stop');
    }
    return _done.future;
  }

  void finish() {
    if (isDone) return;
    _done.complete();
    unawaited(_lines.close());
  }
}
