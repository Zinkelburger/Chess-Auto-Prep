import 'dart:async';
import 'package:stockfish/stockfish.dart';
import 'engine_connection.dart';

class StockfishPackageConnection implements EngineConnection {
  final Stockfish _engine;
  final StreamController<String> _stdoutController = StreamController<String>();
  late final StreamSubscription _subscription;

  StockfishPackageConnection() : _engine = Stockfish() {
    _subscription = _engine.stdout.listen((line) {
      _stdoutController.add(line);
    });
  }

  @override
  Stream<String> get stdout => _stdoutController.stream;

  @override
  Future<void> waitForReady() {
    if (_engine.state.value == StockfishState.ready) return Future.value();
    final completer = Completer<void>();
    void listener() {
      if (_engine.state.value == StockfishState.ready) {
        _engine.state.removeListener(listener);
        completer.complete();
      }
    }
    _engine.state.addListener(listener);
    return completer.future;
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
