import 'dart:async';

import 'package:chess_auto_prep/services/engine/engine_connection.dart';
import 'package:chess_auto_prep/services/engine/engine_search_budget.dart';
import 'package:chess_auto_prep/services/engine/engine_serial_queue.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:flutter_test/flutter_test.dart';

class _Connection implements EngineConnection {
  final output = StreamController<String>.broadcast();
  final closed = Completer<void>();
  final commands = <String>[];
  bool answerReady = true;
  String? throwOn;
  bool disposed = false;
  bool failDispose = false;
  @override
  Stream<String> get stdout => output.stream;
  @override
  Future<void> get done => closed.future;
  @override
  Future<void> waitForReady() async {}
  @override
  void sendCommand(String command) {
    commands.add(command);
    if (command == throwOn) throw StateError('Broken pipe');
    if (command == 'isready' && answerReady) output.add('readyok');
  }

  void finish(int cp, {String pv = 'e2e4'}) {
    output.add('info depth 8 score cp $cp pv $pv');
    output.add('bestmove ${pv.split(' ').first}');
  }

  int get searches => commands.where((c) => c.startsWith('go ')).length;
  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    closed.complete();
    unawaited(output.close());
    if (failDispose) throw StateError('Teardown failed');
  }
}

Future<void> flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Connection connection;
  late EvalWorker worker;
  late EngineSearchBudget budget;
  setUp(() async {
    connection = _Connection();
    budget = EngineSearchBudget(capacity: () => 2);
    worker = EvalWorker(
      connection,
      budget: budget,
      protocolTimeout: const Duration(milliseconds: 100),
    );
    await worker.init();
  });
  tearDown(() async {
    worker.dispose();
    await flush();
    expect(budget.activeThreads, 0);
  });

  test(
    'bulk reuse waits for old bestmove and never assigns old PV to new FEN',
    () async {
      final pool = StockfishPool.fresh()..addWorkerForTest(worker);
      addTearDown(pool.dispose);
      final old = pool.evaluateFen('old position', 20);
      final cancelled = expectLater(old, throwsA(isA<EngineSearchCancelled>()));
      await flush();
      pool.stopAll();
      await cancelled;
      final next = pool.evaluateFen('new position', 20);
      await flush();
      connection.output.add('readyok');
      connection.output.add('info depth 19 score cp 123 pv e2e4');
      await flush();
      expect(connection.searches, 1);
      expect(budget.activeThreads, 1); // stop has not yet released the CPU.
      connection.finish(123);
      await flush();
      expect(connection.searches, 2);
      connection.finish(-45, pv: 'd2d4');
      final result = await next;
      expect(result.scoreCp, -45);
      expect(result.pv, ['d2d4']);
    },
  );

  test(
    'missing stop acknowledgment retires process and frees admission',
    () async {
      final old = worker.evaluateFen('old', 20);
      final cancelled = expectLater(old, throwsA(isA<EngineSearchCancelled>()));
      await flush();
      worker.stop();
      await cancelled;
      final next = worker.evaluateFen('next', 20);
      await expectLater(next, throwsA(isA<TimeoutException>()));
      expect(worker.isDead, isTrue);
      expect(connection.disposed, isTrue);
      expect(connection.searches, 1);
      await flush();
      expect(budget.activeThreads, 0);
    },
  );

  test(
    'stop while waiting for ready prevents go and preserves reuse',
    () async {
      connection.answerReady = false;
      final pending = worker.evaluateFen('cancelled', 8);
      final cancelled = expectLater(
        pending,
        throwsA(isA<EngineSearchCancelled>()),
      );
      await flush();
      worker.stop();
      await cancelled;
      connection.output.add('readyok');
      await flush();
      expect(connection.searches, 0);
      connection.answerReady = true;
      final next = worker.evaluateFen('next', 8);
      await flush();
      connection.finish(9);
      expect((await next).scoreCp, 9);
    },
  );

  test(
    'queued CPU admission is cancelled without launching a search',
    () async {
      final held = await budget.acquire(2, EngineSearchCancellation());
      final pending = worker.evaluateFen('queued', 8);
      final cancelled = expectLater(
        pending,
        throwsA(isA<EngineSearchCancelled>()),
      );
      await flush();
      worker.stop();
      await cancelled;
      await flush();
      held.release();
      await flush();
      expect(connection.searches, 0);
    },
  );

  test(
    'crash while awaiting CPU aborts request and removes admission',
    () async {
      final held = await budget.acquire(2, EngineSearchCancellation());
      final pending = worker.evaluateFen('queued', 8);
      final failed = expectLater(pending, throwsStateError);
      await flush();
      connection.closed.complete();
      // The fake's dispose must tolerate an already exited process.
      connection.disposed = true;
      await failed;
      await flush();
      held.release();
      await connection.output.close();
      expect(connection.searches, 0);
    },
  );

  test(
    'synchronous isready write failure is handled and retires worker',
    () async {
      connection.throwOn = 'isready';
      await expectLater(worker.evaluateFen('broken', 8), throwsStateError);
      expect(worker.isDead, isTrue);
      expect(connection.disposed, isTrue);
    },
  );

  test(
    'options wait for bestmove and single PV is restored for evaluations',
    () async {
      final discovery = worker.runDiscovery('root', 8, 3, false);
      await flush();
      final resizing = worker.setHash(64);
      await flush();
      expect(
        connection.commands,
        isNot(contains('setoption name Hash value 64')),
      );
      connection.finish(20);
      expect((await discovery).lines.single.scoreCp, -20);
      await resizing;
      final next = worker.evaluateFen('next', 8);
      await flush();
      expect(connection.commands, contains('setoption name MultiPV value 1'));
      connection.finish(3);
      await next;
    },
  );

  test('transport teardown errors still release waiters and CPU', () async {
    connection.failDispose = true;
    final pending = worker.evaluateFen('running', 8);
    final failed = expectLater(pending, throwsStateError);
    await flush();
    worker.dispose();
    await failed;
    expect(worker.isDead, isTrue);
    await flush();
    expect(budget.activeThreads, 0);
  });

  test('reentrant transactions remain ordered', () async {
    final queue = EngineSerialQueue();
    final order = <String>[];
    final gate = Completer<void>();
    late Future<void> nested;
    final first = queue.run(() async {
      order.add('first starts');
      nested = queue.run(() async => order.add('second'));
      await gate.future;
      order.add('first ends');
    });
    await flush();
    expect(order, ['first starts']);
    gate.complete();
    await first;
    await nested;
    expect(order, ['first starts', 'first ends', 'second']);
  });

  test('serial transactions recover after caller-visible errors', () async {
    final queue = EngineSerialQueue();
    await expectLater(
      queue.run<void>(() async => throw StateError('failed')),
      throwsStateError,
    );
    expect(await queue.run(() async => 42), 42);
  });
}
