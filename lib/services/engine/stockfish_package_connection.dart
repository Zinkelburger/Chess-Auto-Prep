import 'dart:async';
import 'package:stockfish/stockfish.dart';
import 'engine_connection.dart';
import 'uci_handshake.dart';

class StockfishPackageConnection implements EngineConnection {
  final Stockfish _engine;
  final StreamController<String> _stdoutController =
      StreamController<String>.broadcast();
  late final StreamSubscription _subscription;
  final Completer<void> _done = Completer<void>();
  bool _disposed = false;

  StockfishPackageConnection({Stockfish? engine})
    : _engine = engine ?? Stockfish() {
    _subscription = _engine.stdout.listen((line) {
      if (!_disposed) _stdoutController.add(line);
    });
    _engine.state.addListener(_onEngineState);
    _onEngineState();
  }

  void _onEngineState() {
    if (_disposed) {
      _disposeWhenReady();
      return;
    }
    final state = _engine.state.value;
    if (state == StockfishState.error || state == StockfishState.disposed) {
      if (!_done.isCompleted) _done.complete();
    }
  }

  @override
  Stream<String> get stdout => _stdoutController.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> waitForReady() async {
    if (_disposed) throw StateError('Engine disposed');
    if (_engine.state.value != StockfishState.ready) {
      final ready = Completer<void>();
      void listener() {
        if (_engine.state.value == StockfishState.ready && !ready.isCompleted) {
          ready.complete();
        }
      }

      _engine.state.addListener(listener);
      try {
        await Future.any([
          ready.future,
          done.then<void>(
            (_) => throw StateError('Engine closed during startup'),
          ),
        ]).timeout(const Duration(seconds: 10));
      } finally {
        _engine.state.removeListener(listener);
      }
    }
    await performUciHandshake(this);
  }

  @override
  void sendCommand(String command) {
    if (_disposed) throw StateError('Engine disposed');
    _engine.stdin = command;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (!_done.isCompleted) _done.complete();
    unawaited(_subscription.cancel());
    unawaited(_stdoutController.close());
    _disposeWhenReady();
  }

  void _disposeWhenReady() {
    final state = _engine.state.value;
    // package:stockfish dispose writes "quit", which is only legal when ready.
    // Keep the listener during startup so a late successful start is quit too.
    if (state == StockfishState.starting) return;
    _engine.state.removeListener(_onEngineState);
    if (state == StockfishState.ready) _engine.dispose();
  }
}
