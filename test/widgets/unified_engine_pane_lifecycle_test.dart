import 'package:chess_auto_prep/app/engine_runtime.dart';
import '../support/runtime_settings.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'dart:async';

import 'package:chess_auto_prep/features/settings/controllers/engine_settings.dart';
import 'package:chess_auto_prep/services/analysis_service.dart';
import 'package:chess_auto_prep/services/engine/engine_connection.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';
import 'package:chess_auto_prep/services/engine/stockfish_connection_factory.dart';
import 'package:chess_auto_prep/widgets/engine/unified_engine_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const _e4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

class _Connection implements EngineConnection {
  final output = StreamController<String>.broadcast();
  final closed = Completer<void>();
  final commands = <String>[];
  bool disposed = false;
  bool searching = false;
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
    if (command == 'stop' && searching) {
      searching = false;
      output.add('bestmove e2e4');
    }
  }

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    closed.complete();
    unawaited(output.close());
  }
}

Future<void> pumpFrames(WidgetTester tester) async {
  // Discovery is deliberately left running; its spinner never settles.
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

RuntimeSettings? _runtimeSettings;
RuntimeSettings get runtimeSettings => _runtimeSettings ??= testRuntimeSettings(
  values: {
    'engine_settings.show_maia': false,
    'engine_settings.show_stockfish': true,
  },
);
EngineRuntime get engines => testEngines(runtimeSettings);
EngineLifecycle get lifecycle => engines.lifecycle;
void main() {
  setUp(() {
    _runtimeSettings = null;
    addTearDown(() => _runtimeSettings?.dispose());
  });
  late List<_Connection> connections;

  setUp(() {
    SharedPreferences.setMockInitialValues({});

    connections = [];
    StockfishConnectionFactory.createForTest = () async {
      final connection = _Connection();
      connections.add(connection);
      return connection;
    };
  });
  tearDown(() {
    StockfishConnectionFactory.createForTest = null;
  });

  Widget pane({
    String fen = _fen,
    bool active = true,
    AnalysisService? analysis,
  }) => MaterialApp(
    home: Scaffold(
      body: UnifiedEnginePane(
        fen: fen,
        isActive: active,
        analysis: analysis,
        compact: true,
      ),
    ),
  );

  testWidgets('actual pane toggles, navigates and retains its paused process', (
    tester,
  ) async {
    await pumpRuntimeWidget(tester, runtimeSettings, pane());
    await pumpFrames(tester);
    expect(connections, hasLength(1));
    final connection = connections.single;
    expect(connection.searching, isFalse);
    await lifecycle.toggleOn();
    await pumpFrames(tester);
    expect(connection.commands.where((c) => c.startsWith('go ')), hasLength(1));
    lifecycle.onPositionChanged(_fen);
    lifecycle.onAnalysisComplete();
    await pumpFrames(tester);
    expect(connection.commands.where((c) => c.startsWith('go ')), hasLength(1));
    await pumpRuntimeWidget(tester, runtimeSettings, pane(fen: _e4));
    await pumpFrames(tester);
    expect(connection.commands.where((c) => c.startsWith('go ')), hasLength(2));
    expect(connection.commands, contains('position fen $_e4'));
    await lifecycle.toggleOff();
    await pumpFrames(tester);
    expect(connection.searching, isFalse);
    expect(connection.disposed, isFalse);
    await lifecycle.toggleOn();
    await pumpFrames(tester);
    expect(connection.commands.where((c) => c.startsWith('go ')), hasLength(3));
    await pumpRuntimeWidget(tester, runtimeSettings, const SizedBox());
    await tester.pump();
    expect(connection.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing an injected service detaches the old session', (
    tester,
  ) async {
    final first = AnalysisService(engine: engines.board);
    final second = AnalysisService(engine: engines.board);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await pumpRuntimeWidget(tester, runtimeSettings, pane(analysis: first));
    await pumpFrames(tester);
    await lifecycle.toggleOn();
    await pumpFrames(tester);
    await pumpRuntimeWidget(tester, runtimeSettings, pane(analysis: second));
    await pumpFrames(tester);
    final connection = connections.single;
    expect(connection.commands.where((c) => c.startsWith('go ')), hasLength(2));
    first.cancel();
    expect(connection.searching, isTrue);
    await pumpRuntimeWidget(tester, runtimeSettings, const SizedBox());
    await pumpFrames(tester);
    // The pane detaches a borrowed service but leaves its notifier usable.
    expect(second.poolStatus.value.phase, PoolPhase.idle);
    expect(connection.disposed, isTrue);
  });

  testWidgets(
    'inactive actual pane cannot cancel another session on settings changes',
    (tester) async {
      final active = AnalysisService(engine: engines.board);
      final inactive = AnalysisService(engine: engines.board);
      addTearDown(active.dispose);
      addTearDown(inactive.dispose);
      await active.prepare();
      await pumpRuntimeWidget(
        tester,
        runtimeSettings,
        pane(active: false, analysis: inactive),
      );
      await pumpFrames(tester);
      final discovery = active.runDiscovery(fen: _fen, depth: 20, multiPv: 3);
      await pumpFrames(tester);
      final connection = connections.single;
      expect(connection.searching, isTrue);
      runtimeSettings.engine.toggleAnalysisColumnMuted(EngineSettings.colEval);
      await pumpFrames(tester);
      expect(connection.commands, isNot(contains('stop')));
      connection.output.add('info depth 20 multipv 1 score cp 25 pv e2e4');
      connection.output.add('bestmove e2e4');
      connection.searching = false;
      await pumpFrames(tester);
      expect((await discovery).lines.single.scoreCp, 25);
      await pumpRuntimeWidget(tester, runtimeSettings, const SizedBox());
      await tester.pump();
      expect(engines.board.workerCount, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
