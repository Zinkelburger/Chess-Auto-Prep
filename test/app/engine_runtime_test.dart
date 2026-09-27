import 'dart:async';

import 'package:chess_auto_prep/app/engine_runtime.dart';
import 'package:chess_auto_prep/services/engine/engine_connection.dart';
import 'package:chess_auto_prep/services/engine/engine_search_budget.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/runtime_settings.dart';
import '../support/scripted_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'shutdown retires board, pool, queued admission and forbids resurrection',
    () async {
      final settings = testRuntimeSettings(
        values: {'engine_settings.cores': 1},
      );
      await settings.load();
      final connections = <ScriptedEngine>[];
      final runtime = EngineRuntime(
        settings: settings.engine,
        createConnection: () async {
          final connection = ScriptedEngine();
          connections.add(connection);
          return connection;
        },
      );
      addTearDown(settings.dispose);
      addTearDown(runtime.dispose);
      final board = runtime.board.createSession();
      await board.prepare();
      await runtime.pool.ensureWorkers(1);
      expect(connections, hasLength(2));
      final admitted = await runtime.budget.acquire(
        1,
        EngineSearchCancellation(),
      );
      final queued = runtime.budget.acquire(1, EngineSearchCancellation());
      final cancelled = expectLater(
        queued,
        throwsA(isA<EngineSearchCancelled>()),
      );
      runtime.dispose();
      runtime.dispose();
      await cancelled;
      admitted.release();
      expect(runtime.budget.activeThreads, 0);
      expect(runtime.pool.workerCount, 0);
      expect(connections.every((connection) => connection.disposed), isTrue);
      await expectLater(runtime.pool.ensureWorkers(1), throwsStateError);
      await expectLater(runtime.lifecycle.toggleOn(), throwsStateError);
      expect(runtime.board.createSession, throwsStateError);
      expect(connections, hasLength(2));
    },
  );

  test('late native startup is retired when its application closes', () async {
    final settings = testRuntimeSettings();
    final pending = Completer<EngineConnection?>();
    final runtime = EngineRuntime(
      settings: settings.engine,
      createConnection: () => pending.future,
    );
    addTearDown(settings.dispose);
    addTearDown(runtime.dispose);
    final provisioning = runtime.pool.ensureWorkers(1);
    await Future<void>.delayed(Duration.zero);
    runtime.dispose();
    final connection = ScriptedEngine();
    pending.complete(connection);
    await provisioning;
    expect(connection.disposed, isTrue);
    expect(runtime.pool.workerCount, 0);
  });

  test(
    'lease excludes concurrent callers and retries after unavailable workers',
    () async {
      final settings = testRuntimeSettings();
      var fail = true;
      final runtime = EngineRuntime(
        settings: settings.engine,
        createConnection: () async {
          if (fail) throw StateError('spawn failed');
          return ScriptedEngine();
        },
      );
      addTearDown(settings.dispose);
      addTearDown(runtime.dispose);
      await expectLater(
        runtime.lease.run(() async => runtime.pool.acquire()),
        throwsStateError,
      );
      expect(runtime.lease.isBusy, isFalse);
      fail = false;
      final release = Completer<void>();
      final entered = Completer<void>();
      final first = runtime.lease.run(() async {
        entered.complete();
        await release.future;
        return 7;
      });
      await expectLater(runtime.lease.run(() async => 2), throwsStateError);
      await entered.future;
      expect(runtime.lease.isBusy, isTrue);
      release.complete();
      expect(await first, 7);
      expect(runtime.lease.isBusy, isFalse);
      expect(runtime.pool.workerCount, 0);
    },
  );
}
