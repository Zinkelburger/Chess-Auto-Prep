/// Unit tests for [StockfishPool] crash recovery and cancel-abort.
library;

import 'dart:async';

import 'package:chess_auto_prep/services/engine/engine_connection.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeConnection implements EngineConnection {
  final _stdout = StreamController<String>.broadcast();
  final _done = Completer<void>();
  final commands = <String>[];
  var disposed = false;

  @override
  Stream<String> get stdout => _stdout.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> waitForReady() async {}

  @override
  void sendCommand(String command) {
    commands.add(command);
    if (command == 'isready') {
      scheduleMicrotask(() {
        if (!_stdout.isClosed) _stdout.add('readyok');
      });
    }
  }

  void completeEval({int cp = 12}) {
    _stdout.add('info depth 8 score cp $cp pv e2e4');
    _stdout.add('bestmove e2e4');
  }

  void crash() {
    if (!_done.isCompleted) _done.complete();
    if (!_stdout.isClosed) {
      _stdout.addError(StateError('Stockfish process exited (1)'));
    }
  }

  @override
  void dispose() {
    disposed = true;
    unawaited(_stdout.close());
  }
}

void main() {
  test('stopAll aborts an in-flight evaluateFen', () async {
    final conn = _FakeConnection();
    final pool = StockfishPool.fresh();
    final worker = EvalWorker(conn);
    await worker.init(hashMb: 16, threads: 1);
    pool.addWorkerForTest(worker);

    final eval = pool.evaluateFen(
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      20,
    );
    await Future<void>.delayed(Duration.zero);
    pool.stopAll();

    await expectLater(eval, throwsA(isA<StateError>()));
    expect(conn.commands, contains('stop'));
    pool.dispose();
  });

  test(
    'forEachParallel UCI-stops the in-flight item when stopWhen flips',
    () async {
      final conn = _FakeConnection();
      final pool = StockfishPool.fresh();
      final worker = EvalWorker(conn);
      await worker.init(hashMb: 16, threads: 1);
      pool.addWorkerForTest(worker);

      var stop = false;
      final fens = [
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
      ];

      final done = pool.forEachParallel<String>(fens, (w, fen) async {
        final pending = w.evaluateFen(fen, 20);
        stop = true;
        await pending;
      }, stopWhen: () => stop);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await done.timeout(const Duration(seconds: 2));
      expect(conn.commands.where((c) => c == 'stop').length, greaterThan(0));
      pool.dispose();
    },
  );

  test('dead worker is dropped and a waiter is not stuck forever', () async {
    final conn = _FakeConnection();
    final pool = StockfishPool.fresh();
    final worker = EvalWorker(conn);
    await worker.init(hashMb: 16, threads: 1);
    pool.addWorkerForTest(worker);

    expect(pool.workerCount, 1);

    final eval = worker.evaluateFen(
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      20,
    );
    await Future<void>.delayed(Duration.zero);
    conn.crash();

    await expectLater(eval, throwsA(isA<StateError>()));
    // Crash retirement is async; give the pool a turn to drop the corpse.
    await Future<void>.delayed(Duration.zero);
    expect(pool.workerCount, 0);
    pool.dispose();
  });
}
