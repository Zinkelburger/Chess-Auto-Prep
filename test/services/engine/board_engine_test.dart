import 'dart:async';

import 'package:chess_auto_prep/models/engine_settings.dart';
import 'package:chess_auto_prep/services/engine/board_engine.dart';
import 'package:chess_auto_prep/services/engine/engine_connection.dart';
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
  final a = Object();
  final b = Object();

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
  });
  tearDown(() => board.dispose());

  Future<dynamic> search(
    Object owner, {
    String fen = _fen,
    void Function()? onProgress,
  }) => board.discover(
    owner,
    fen: fen,
    depth: 15,
    multiPv: 3,
    whiteToMove: true,
    onProgress: (_) => onProgress?.call(),
  );

  test(
    'many boards prepare exactly one configured process without searching',
    () async {
      await Future.wait([for (var i = 0; i < 10; i++) board.prepare(Object())]);
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
      await board.prepare(a);
      final engine = engines.single;
      final first = search(a);
      await flush();
      board.pause(a);
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
      await board.prepare(a);
      await board.prepare(b);
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
      board.pause(a);
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
      await board.prepare(a);
      final engine = engines.single..acknowledgeStop = false;
      final old = search(a);
      await flush();
      final next = search(b, fen: '$_fen moves e2e4');
      await flush();
      expect(await old, isNull);
      board.pause(a); // An old pane cannot cancel its successor.
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
      await board.prepare(a);
      board.detach(a);
      await board.prepare(b);
      await flush();
      expect(engines, hasLength(1));
      expect(engines.single.disposed, isFalse);
      board.detach(b);
      await flush();
      expect(engines.single.disposed, isTrue);
    },
  );

  test(
    'suspension releases memory and resume prepares only one process',
    () async {
      await board.prepare(a);
      await board.prepare(b);
      board.suspend();
      expect(engines.single.disposed, isTrue);
      await board.prepare(a);
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
      final preparing = board.prepare(a);
      await flush();
      board.detach(a);
      await flush();
      final engine = _Engine();
      created.complete(engine);
      await preparing;
      expect(engine.disposed, isTrue);
      expect(engine.commands, isEmpty);
    },
  );
}
