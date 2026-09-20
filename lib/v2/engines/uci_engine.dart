import 'dart:async';

import '../chess/fen.dart';
import 'engine.dart';
import 'engine_line.dart';
import 'uci_process.dart';

/// The UCI conversation with one engine process.
///
/// Searches are serialised: a new one waits for the previous `bestmove`
/// before sending `go`, and `info` lines go to whichever search the engine
/// is on. That is what keeps a stale evaluation off the board.
final class UciEngine implements Engine {
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
  final _exited = Completer<void>();
  String _name = 'UCI engine';
  Completer<void>? _awaiting;
  String _awaitedToken = '';

  /// The search the engine is on; `info` lines go here.
  _UciSearch? _current;

  /// The search most recently asked for, which the next one waits behind.
  _UciSearch? _latest;
  Future<void> _turn = Future.value();

  @override
  String get name => _name;

  int get pid => _process.pid;

  @override
  Future<void> get exited => _exited.future;

  @override
  Search analyse(Fen fen, {required int multiPv}) {
    final search = _UciSearch(_send);
    final previous = _latest;
    _latest = search;
    _turn = _turn.then((_) => _begin(search, previous, fen, multiPv));
    return search.public;
  }

  Future<void> _begin(
    _UciSearch search,
    _UciSearch? previous,
    Fen fen,
    int multiPv,
  ) async {
    await previous?.stop();
    if (_exited.isCompleted) return search.finish();
    if (search.isDone) return; // stopped before it began
    _current = search;
    _send('setoption name MultiPV value $multiPv');
    _send('position fen ${fen.value}');
    _send('go infinite');
    search.markRunning();
  }

  @override
  Future<void> quit() async {
    if (_exited.isCompleted) return;
    _send('quit');
    await exited.timeout(const Duration(seconds: 2), onTimeout: _process.kill);
  }

  void _send(String line) => _process.send(line);

  Future<void> _expect(String token) {
    _awaitedToken = token;
    return (_awaiting = Completer<void>()).future;
  }

  void _onLine(String line) {
    if (line == _awaitedToken) {
      _awaiting?.complete();
      _awaiting = null;
      _awaitedToken = '';
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
    _awaiting?.completeError(const EngineFailure('engine exited'));
    _awaiting = null;
    _current?.finish();
    _current = null;
    _exited.complete();
  }
}

/// A search as the engine sees it: queued, running, or finished once
/// `bestmove` arrived.
final class _UciSearch {
  _UciSearch(this._send);

  final void Function(String line) _send;
  final _lines = StreamController<EngineLine>();
  final _done = Completer<void>();
  bool _running = false;
  bool _stopSent = false;
  late final public = Search(lines: _lines.stream, stop: stop);

  bool get isDone => _done.isCompleted;

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
