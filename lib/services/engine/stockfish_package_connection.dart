import 'dart:async';
import 'package:stockfish/stockfish.dart';
import 'engine_connection.dart';

class StockfishPackageConnection implements EngineConnection {
  final Stockfish _engine;
  final StreamController<String> _stdoutController = StreamController<String>.broadcast();
  late final StreamSubscription _subscription;

  StockfishPackageConnection() : _engine = Stockfish() {
    _subscription = _engine.stdout.listen((line) {
      _stdoutController.add(line);
    });
  }

  @override
  Stream<String> get stdout => _stdoutController.stream;

  @override
  Future<void> waitForReady() async {
    if (_engine.state.value != StockfishState.ready) {
      final completer = Completer<void>();
      void listener() {
        if (_engine.state.value == StockfishState.ready) {
          _engine.state.removeListener(listener);
          completer.complete();
        }
      }
      _engine.state.addListener(listener);
      await completer.future;
    }

    final uciOk = Completer<void>();
    final readyOk = Completer<void>();
    late StreamSubscription sub;
    sub = stdout.listen((line) {
      if (line.trim() == 'uciok' && !uciOk.isCompleted) {
        uciOk.complete();
      } else if (line.trim() == 'readyok' && !readyOk.isCompleted) {
        readyOk.complete();
      }
    });

    sendCommand('uci');
    await uciOk.future.timeout(const Duration(seconds: 10));

    sendCommand('isready');
    await readyOk.future.timeout(const Duration(seconds: 10));

    await sub.cancel();
    // Threads / Hash are configured by EvalWorker.init() after this returns.
  }

  @override
  void sendCommand(String command) {
    _engine.stdin = command;
  }

  @override
  void dispose() {
    _subscription.cancel();
    _engine.dispose();
    _stdoutController.close();
  }
}
