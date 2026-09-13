import 'dart:async';

import 'package:chess_auto_prep/models/engine_settings.dart';
import 'package:chess_auto_prep/services/analysis_service.dart';
import 'package:chess_auto_prep/services/engine/board_engine.dart';
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

void main() {
  late List<_Connection> connections;
  final lifecycle = EngineLifecycle.instance;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    lifecycle.resetForTest();
    EngineLifecycle.testMode = true;
    EngineSettings.instance.showMaia = false;
    EngineSettings.instance.showStockfish = true;
    connections = [];
    StockfishConnectionFactory.createForTest = () async {
      final connection = _Connection();
      connections.add(connection);
      return connection;
    };
  });
  tearDown(() {
    lifecycle.resetForTest();
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
    await tester.pumpWidget(pane());
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
    await tester.pumpWidget(pane(fen: _e4));
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
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(connection.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing an injected service detaches the old session', (
    tester,
  ) async {
    final first = AnalysisService();
    final second = AnalysisService();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(pane(analysis: first));
    await pumpFrames(tester);
    await lifecycle.toggleOn();
    await pumpFrames(tester);
    await tester.pumpWidget(pane(analysis: second));
    await pumpFrames(tester);
    final connection = connections.single;
    expect(connection.commands.where((c) => c.startsWith('go ')), hasLength(2));
    first.cancel();
    expect(connection.searching, isTrue);
    await tester.pumpWidget(const SizedBox());
    await pumpFrames(tester);
    // The pane detaches a borrowed service but leaves its notifier usable.
    expect(second.poolStatus.value.phase, 'idle');
    expect(connection.disposed, isTrue);
  });

  testWidgets(
    'inactive actual pane cannot cancel another session on settings changes',
    (tester) async {
      final active = AnalysisService();
      final inactive = AnalysisService();
      addTearDown(active.dispose);
      addTearDown(inactive.dispose);
      await active.prepare();
      await tester.pumpWidget(pane(active: false, analysis: inactive));
      await pumpFrames(tester);
      final discovery = active.runDiscovery(fen: _fen, depth: 20, multiPv: 3);
      await pumpFrames(tester);
      final connection = connections.single;
      expect(connection.searching, isTrue);
      EngineSettings.instance.toggleAnalysisColumnMuted(EngineSettings.colEval);
      await pumpFrames(tester);
      expect(connection.commands, isNot(contains('stop')));
      connection.output.add('info depth 20 multipv 1 score cp 25 pv e2e4');
      connection.output.add('bestmove e2e4');
      connection.searching = false;
      await pumpFrames(tester);
      expect((await discovery).lines.single.scoreCp, 25);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(BoardEngine.instance.workerCount, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
