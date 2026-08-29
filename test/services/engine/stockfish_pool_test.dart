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

  /// When set, every `go` is answered with this cp and a bestmove on the
  /// next microtask, so batches complete without a test scripting each one.
  int? autoAnswerCp;

  @override
  void sendCommand(String command) {
    commands.add(command);
    if (command == 'isready') {
      scheduleMicrotask(() {
        if (!_stdout.isClosed) _stdout.add('readyok');
      });
    } else if (command.startsWith('go ') && autoAnswerCp != null) {
      final cp = autoAnswerCp!;
      scheduleMicrotask(() {
        if (!_stdout.isClosed) completeEval(cp: cp);
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

  group('evaluateMany', () {
    test('runs on worker lanes and returns results in input order', () async {
      final pool = StockfishPool.fresh();
      final conns = <_FakeConnection>[];
      for (var i = 0; i < 2; i++) {
        final conn = _FakeConnection()..autoAnswerCp = 10 + i;
        conns.add(conn);
        final worker = EvalWorker(conn);
        await worker.init(hashMb: 16, threads: 1);
        pool.addWorkerForTest(worker);
      }

      // Far more positions than workers: every one must be answered, none
      // may sit as an `acquire` waiter counting down its timeout.
      final fens = List.generate(
        40,
        (i) => 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - $i 1',
      );
      final results = await pool.evaluateMany(fens, 8);
      expect(results, hasLength(40));
      expect(results.map((r) => r.scoreCp), everyElement(anyOf(10, 11)));

      // Both workers took a share of the batch.
      final goCounts = [
        for (final c in conns)
          c.commands.where((x) => x.startsWith('go ')).length,
      ];
      expect(goCounts.reduce((a, b) => a + b), 40);
      expect(goCounts.every((n) => n > 0), isTrue);
      pool.dispose();
    });

    test('an empty batch is an empty result', () async {
      final pool = StockfishPool.fresh();
      expect(await pool.evaluateMany(const [], 8), isEmpty);
    });
  });

  group('runDiscovery searchMoves', () {
    test('restricts the search to the given root moves', () async {
      final conn = _FakeConnection()..autoAnswerCp = 5;
      final worker = EvalWorker(conn);
      await worker.init(hashMb: 16, threads: 1);

      await worker.runDiscovery(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        12,
        3,
        true,
        searchMoves: const ['e2e4', 'd2d4', 'c2c4'],
      );
      expect(conn.commands, contains('setoption name MultiPV value 3'));
      expect(conn.commands, contains('go depth 12 searchmoves e2e4 d2d4 c2c4'));
      worker.dispose();
    });

    test('without searchMoves the plain go is sent', () async {
      final conn = _FakeConnection()..autoAnswerCp = 5;
      final worker = EvalWorker(conn);
      await worker.init(hashMb: 16, threads: 1);
      await worker.runDiscovery(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        12,
        1,
        true,
      );
      expect(conn.commands, contains('go depth 12'));
      worker.dispose();
    });
  });

  group('prepareForTreeBuild sizing', () {
    test('lanes are the worker setting capped by the thread budget', () {
      expect(StockfishPool.laneCountFor(8, workers: 4), 4);
      expect(StockfishPool.laneCountFor(2, workers: 4), 2);
      expect(StockfishPool.laneCountFor(0, workers: 4), 1);
      expect(StockfishPool.laneCountFor(8, workers: 0), 1);
    });

    test('leftover threads go to each worker, never below one', () {
      expect(StockfishPool.threadsPerLane(12, 4), 3);
      expect(StockfishPool.threadsPerLane(4, 4), 1);
      expect(StockfishPool.threadsPerLane(3, 4), 1);
      expect(StockfishPool.threadsPerLane(6, 0), 6);
    });
  });

  group('concurrencyLimit', () {
    Future<StockfishPool> poolWith(int workers) async {
      final pool = StockfishPool.fresh();
      for (var i = 0; i < workers; i++) {
        final worker = EvalWorker(_FakeConnection());
        await worker.init(hashMb: 16, threads: 1);
        pool.addWorkerForTest(worker);
      }
      return pool;
    }

    test('is the worker count when nothing asked for fewer', () async {
      final pool = await poolWith(3);
      expect(pool.concurrencyLimit, 3);
      pool.dispose();
    });

    test('drops to what the current consumer provisioned', () async {
      // The pool only grows: a build that provisions 2 lanes under a small
      // thread budget still finds the 4 workers interactive analysis left.
      final pool = await poolWith(4);
      pool.setTargetCountForTest(2);
      expect(pool.concurrencyLimit, 2);
      pool.dispose();
    });

    test('never exceeds the workers that actually exist', () async {
      final pool = await poolWith(2);
      pool.setTargetCountForTest(8);
      expect(pool.concurrencyLimit, 2);
      pool.dispose();
    });

    test('caps how many items forEachParallel runs at once', () async {
      final pool = await poolWith(4);
      pool.setTargetCountForTest(2);

      var live = 0;
      var peak = 0;
      await pool.forEachParallel<int>(List.generate(8, (i) => i), (_, _) async {
        live++;
        if (live > peak) peak = live;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        live--;
      });

      expect(peak, 2, reason: 'the budget, not the worker count');
      pool.dispose();
    });
  });
}
