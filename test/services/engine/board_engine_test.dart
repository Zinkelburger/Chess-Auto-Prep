import 'dart:async';

import 'package:chess_auto_prep/models/engine_settings.dart';
import 'package:chess_auto_prep/services/engine/board_engine.dart';
import 'package:chess_auto_prep/services/engine/engine_connection.dart';
import 'package:chess_auto_prep/services/engine/engine_search_budget.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

class _Engine implements EngineConnection {
  final output = StreamController<String>.broadcast();
  final closed = Completer<void>();
  final commands = <String>[];
  bool disposed = false;
  bool searching = false;
  bool acknowledgeStop = true;

  @override
  Stream<String> get stdout => output.stream;
  @override
  Future<void> get done => closed.future;
  @override
  Future<void> waitForReady() async {}
  @override
  void sendCommand(String command) {
    commands.add(command);
    if (command == 'isready') output.add('readyok');
    if (command.startsWith('go ')) searching = true;
    if (command == 'stop' && searching && acknowledgeStop) finish();
  }

  void progress() =>
      output.add('info depth 1 multipv 1 score cp 20 nodes 10 pv e2e4');
  void finish() {
    searching = false;
    output.add('bestmove e2e4');
  }

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    closed.complete();
    unawaited(output.close());
  }
}

Future<void> flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BoardEngine board;
  late List<_Engine> engines;
  late BoardEngineSession a;
  late BoardEngineSession b;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EngineSettings.instance.cores = 4.clamp(1, EngineSettings.systemCores);
    EngineSettings.instance.hashMb = 128;
    engines = [];
    board = BoardEngine(
      createConnection: () async {
        final engine = _Engine();
        engines.add(engine);
        return engine;
      },
    );
    a = board.createSession();
    b = board.createSession();
  });
  tearDown(() => board.dispose());

  Future<dynamic> search(
    BoardEngineSession owner, {
    String fen = _fen,
    void Function()? onProgress,
  }) => owner.discover(
    fen: fen,
    depth: 15,
    multiPv: 3,
    whiteToMove: true,
    onProgress: (_) => onProgress?.call(),
  );

  test(
    'detached sessions cannot join another pane or stop its search',
    () async {
      await a.prepare();
      final active = search(a);
      await flush();
      expect(await search(b), isNull);
      b.pause();
      expect(engines.single.searching, isTrue);
      engines.single.progress();
      engines.single.finish();
      expect(await active, isNotNull);
      b.dispose();
      await expectLater(b.prepare(), throwsStateError);
      await expectLater(search(b), throwsStateError);
    },
  );

  test('stop timeout replaces process for the next search', () async {
    board.dispose();
    board = BoardEngine(
      protocolTimeout: const Duration(milliseconds: 100),
      createConnection: () async {
        final engine = _Engine()..acknowledgeStop = false;
        engines.add(engine);
        return engine;
      },
    );
    a = board.createSession();
    await a.prepare();
    final old = search(a);
    await flush();
    final next = search(a, fen: 'next');
    expect(await old, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await flush();
    expect(engines, hasLength(2));
    expect(engines.first.disposed, isTrue);
    engines.last.progress();
    engines.last.finish();
    expect(await next, isNotNull);
  });

  test(
    'board and bulk workers share CPU admission, including stop draining',
    () async {
      board.dispose();
      final budget = EngineSearchBudget(capacity: () => 2);
      board = BoardEngine(
        budget: budget,
        createConnection: () async {
          final engine = _Engine()..acknowledgeStop = false;
          engines.add(engine);
          return engine;
        },
      );
      a = board.createSession();
      await a.prepare();
      final bulkConnection = _Engine();
      final bulkWorker = EvalWorker(bulkConnection, budget: budget);
      await bulkWorker.init();
      final pool = StockfishPool.fresh()..addWorkerForTest(bulkWorker);
      addTearDown(pool.dispose);
      final active = search(a);
      await flush();
      expect(budget.activeThreads, 2);
      final bulk = pool.evaluateFen('bulk', 8);
      await flush();
      expect(bulkConnection.searching, isFalse);
      a.pause();
      expect(await active, isNull);
      expect(bulkConnection.searching, isFalse);
      engines.single.finish();
      await flush();
      expect(bulkConnection.searching, isTrue);
      final resumed = search(a);
      await flush();
      expect(budget.activeThreads, 2);
      expect(
        engines.single.commands,
        contains('setoption name Threads value 1'),
      );
      bulkConnection.finish();
      engines.single.progress();
      engines.single.finish();
      await bulk;
      expect(await resumed, isNotNull);
      await flush();
      expect(budget.activeThreads, 0);
    },
  );

  test('settings resize the warm worker between searches', () async {
    await a.prepare();
    final active = search(a);
    await flush();
    EngineSettings.instance.hashMb = 64;
    final prepared = a.prepare();
    await flush();
    expect(
      engines.single.commands,
      isNot(contains('setoption name Hash value 64')),
    );
    a.pause();
    await active;
    await prepared;
    expect(engines, hasLength(1));
    expect(engines.single.commands, contains('setoption name Hash value 64'));
  });

  test(
    'many boards prepare exactly one configured process without searching',
    () async {
      await Future.wait([
        for (var i = 0; i < 10; i++) board.createSession().prepare(),
      ]);
      expect(engines, hasLength(1));
      expect(
        engines.single.commands.where((c) => c.startsWith('go ')),
        isEmpty,
      );
      expect(
        engines.single.commands,
        contains(
          'setoption name Threads value ${EngineSettings.instance.cores}',
        ),
      );
      expect(
        engines.single.commands,
        contains('setoption name Hash value 128'),
      );
      expect(board.workerCount, 1);
    },
  );

  test(
    'pause and resume reuse the process without changing threads or hash',
    () async {
      await a.prepare();
      final engine = engines.single;
      final first = search(a);
      await flush();
      a.pause();
      expect(await first, isNull);
      final second = search(a);
      await flush();
      engine.progress();
      engine.finish();
      expect(await second, isNotNull);
      expect(engines, hasLength(1));
      expect(engine.disposed, isFalse);
      expect(
        engine.commands.where((c) => c.startsWith('setoption name Threads')),
        hasLength(1),
      );
      expect(
        engine.commands.where((c) => c.startsWith('setoption name Hash')),
        hasLength(1),
      );
    },
  );

  test(
    'two views share live discovery and pausing one leaves the other running',
    () async {
      await a.prepare();
      await b.prepare();
      var updatesA = 0;
      var updatesB = 0;
      final first = search(a, onProgress: () => updatesA++);
      final second = search(b, onProgress: () => updatesB++);
      await flush();
      final engine = engines.single;
      engine.progress();
      await flush();
      expect(updatesA, 1);
      expect(updatesB, 1);
      a.pause();
      expect(engine.searching, isTrue);
      engine.progress();
      engine.finish();
      expect(await first, isNull);
      expect(await second, isNotNull);
      expect(updatesA, 1);
      expect(updatesB, 2);
      expect(engine.commands.where((c) => c.startsWith('go ')), hasLength(1));
    },
  );

  test(
    'a new position waits for old bestmove even when readyok arrived first',
    () async {
      await a.prepare();
      final engine = engines.single..acknowledgeStop = false;
      final old = search(a);
      await flush();
      await b.prepare();
      final next = search(b, fen: '$_fen moves e2e4');
      await flush();
      expect(await old, isNull);
      a.pause(); // An old pane cannot cancel its successor.
      engine.output.add('readyok');
      engine.progress(); // Stale PV must not complete the new request.
      await flush();
      expect(engine.commands.where((c) => c.startsWith('go ')), hasLength(1));
      engine.finish();
      await flush();
      expect(engine.commands.where((c) => c.startsWith('go ')), hasLength(2));
      engine.progress();
      engine.finish();
      expect(await next, isNotNull);
    },
  );

  test(
    'last board departure releases process; route replacement reuses it',
    () async {
      await a.prepare();
      a.detach();
      await b.prepare();
      await flush();
      expect(engines, hasLength(1));
      expect(engines.single.disposed, isFalse);
      b.detach();
      await flush();
      expect(engines.single.disposed, isTrue);
    },
  );

  test(
    'suspension releases memory and resume prepares only one process',
    () async {
      await a.prepare();
      await b.prepare();
      board.suspend();
      expect(engines.single.disposed, isTrue);
      await a.prepare();
      expect(await search(a), isNull);
      expect(engines, hasLength(1));
      await board.resume();
      expect(engines, hasLength(2));
      expect(engines.last.commands.where((c) => c.startsWith('go ')), isEmpty);
    },
  );

  test(
    'departure during startup disposes the late connection without searching',
    () async {
      board.dispose();
      final created = Completer<EngineConnection?>();
      board = BoardEngine(createConnection: () => created.future);
      a = board.createSession();
      final preparing = a.prepare();
      await flush();
      a.detach();
      await flush();
      final engine = _Engine();
      created.complete(engine);
      await preparing;
      expect(engine.disposed, isTrue);
      expect(engine.commands, isEmpty);
    },
  );
}
