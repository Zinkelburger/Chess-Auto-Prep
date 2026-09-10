import 'dart:async';

import 'package:chess_auto_prep/services/engine/stockfish_package_connection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stockfish/stockfish.dart';

class _State extends ValueNotifier<StockfishState> {
  _State(super.value);
  bool get observed => hasListeners;
}

class _PackageEngine implements Stockfish {
  _PackageEngine(StockfishState initial) : state = _State(initial);
  @override
  final _State state;
  final output = StreamController<String>.broadcast();
  int quits = 0;
  Future<void> closeOutput() => output.close();
  @override
  Stream<String> get stdout => output.stream;
  @override
  Completer<Stockfish>? get completer => null;
  @override
  set stdin(String command) {
    if (state.value != StockfishState.ready) throw StateError('Not ready');
  }

  @override
  void dispose() {
    stdin = 'quit';
    quits++;
  }
}

void main() {
  for (final state in [StockfishState.error, StockfishState.disposed]) {
    test(
      'disposing a $state package closes the adapter without writing quit',
      () async {
        final engine = _PackageEngine(state);
        final connection = StockfishPackageConnection(engine: engine);
        connection.dispose();
        connection.dispose();
        await connection.done;
        expect(engine.quits, 0);
        expect(engine.state.observed, isFalse);
        await engine.closeOutput();
      },
    );
  }

  test(
    'disposing during startup cancels readiness and quits a late start once',
    () async {
      final engine = _PackageEngine(StockfishState.starting);
      final connection = StockfishPackageConnection(engine: engine);
      final ready = expectLater(connection.waitForReady(), throwsStateError);
      connection.dispose();
      await ready;
      expect(engine.quits, 0);
      expect(engine.state.observed, isTrue);
      engine.state.value = StockfishState.ready;
      expect(engine.quits, 1);
      expect(engine.state.observed, isFalse);
      connection.dispose();
      expect(engine.quits, 1);
      await engine.closeOutput();
    },
  );

  test(
    'failed late startup removes the disposal listener without quit',
    () async {
      final engine = _PackageEngine(StockfishState.starting);
      final connection = StockfishPackageConnection(engine: engine);
      connection.dispose();
      engine.state.value = StockfishState.error;
      expect(engine.quits, 0);
      expect(engine.state.observed, isFalse);
      await engine.closeOutput();
    },
  );
}
