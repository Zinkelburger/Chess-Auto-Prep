import 'dart:async';

import 'package:chess_auto_prep/services/engine/engine_connection.dart';
import 'package:chess_auto_prep/services/engine/stockfish_connection_factory.dart';
import 'package:chess_auto_prep/widgets/engine/inline_engine_bar.dart';
import 'package:flutter/material.dart';
import 'package:chess_auto_prep/models/engine_settings.dart';
import 'package:chess_auto_prep/widgets/common/number_stepper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

class _Connection implements EngineConnection {
  final output = StreamController<String>.broadcast();
  final closed = Completer<void>();
  bool disposed = false;
  final commands = <String>[];
  @override
  Stream<String> get stdout => output.stream;
  @override
  Future<void> get done => closed.future;
  @override
  Future<void> waitForReady() async {}
  @override
  void sendCommand(String command) {
    commands.add(command);
    if (command.startsWith('go ')) {
      final black = commands
          .lastWhere((c) => c.startsWith('position fen'))
          .contains(' b ');
      final pv = black ? 'e7e5 e2e4' : 'e2e4 e7e5';
      output.add('info depth 1 multipv 1 score cp 20 nodes 10 pv $pv');
      output.add('bestmove ${pv.split(' ').first}');
    }
    if (command == 'isready' && !disposed) output.add('readyok');
  }

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    closed.complete();
    unawaited(output.close());
  }
}

void main() {
  const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    StockfishConnectionFactory.createForTest = null;
    if (InlineEngineBar.isEngineEnabled) InlineEngineBar.toggleEngine();
  });

  Widget harness({required bool active}) => MaterialApp(
    home: Scaffold(
      body: TickerMode(
        enabled: active,
        child: const InlineEngineBar(fen: fen),
      ),
    ),
  );

  testWidgets('hidden mode never starts an engine and releases it on leaving', (
    tester,
  ) async {
    final connections = <_Connection>[];
    StockfishConnectionFactory.createForTest = () async {
      final connection = _Connection();
      connections.add(connection);
      return connection;
    };
    await tester.pumpWidget(harness(active: false));
    InlineEngineBar.toggleEngine();
    await tester.pump();
    expect(connections, isEmpty);
    await tester.pumpWidget(harness(active: true));
    await tester.pump();
    expect(connections, hasLength(1));
    await tester.pumpWidget(harness(active: false));
    await tester.pump();
    expect(connections.single.disposed, isTrue);
    await tester.pumpWidget(harness(active: true));
    await tester.pump();
    expect(connections, hasLength(2));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(connections.every((c) => c.disposed), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'threat switches search side, reuses worker, and never inserts a pass line',
    (tester) async {
      final connection = _Connection();
      StockfishConnectionFactory.createForTest = () async => connection;
      var inserted = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InlineEngineBar(
              fen: fen,
              onLineMoveTapped: (_, _) => inserted = true,
            ),
          ),
        ),
      );
      InlineEngineBar.toggleEngine();
      await tester.pumpAndSettle();
      expect(connection.commands, contains('position fen $fen'));
      await tester.tap(find.byTooltip('Show threat'));
      await tester.pumpAndSettle();
      expect(
        connection.commands.lastWhere((c) => c.startsWith('position fen')),
        contains(' b KQkq - 1 1'),
      );
      expect(find.byTooltip('Hide threat'), findsOneWidget);
      expect(connection.disposed, isFalse);
      await tester.tap(find.text('e5').first);
      await tester.pumpAndSettle();
      expect(inserted, isFalse);
      await tester.tap(find.byTooltip('Hide threat'));
      await tester.pumpAndSettle();
      expect(
        connection.commands.lastWhere((c) => c.startsWith('position fen')),
        'position fen $fen',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'compact engine cores read and write the global setting while off',
    (tester) async {
      final settings = EngineSettings.instance;
      final before = settings.cores;
      await tester.pumpWidget(harness(active: true));
      await tester.tap(find.byTooltip('Engine settings'));
      await tester.pumpAndSettle();
      final cores = find.byType(NumberStepper).first;
      final next = before == 1 ? 2.clamp(1, EngineSettings.systemCores) : 1;
      tester.widget<NumberStepper>(cores).onChanged(next);
      await tester.pumpAndSettle();
      expect(settings.cores, next);
      settings.cores = before;
      await tester.pumpAndSettle();
      expect(tester.widget<NumberStepper>(cores).value, before);
      expect(InlineEngineBar.isEngineEnabled, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('navigation clears threat mode and check disables the target', (
    tester,
  ) async {
    StockfishConnectionFactory.createForTest = () async => _Connection();
    await tester.pumpWidget(harness(active: true));
    InlineEngineBar.toggleEngine();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show threat'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hide threat'), findsOneWidget);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TickerMode(
            enabled: true,
            child: InlineEngineBar(fen: '4k3/8/8/8/8/8/4R3/4K3 b - - 0 1'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final target = find.byTooltip('Show threat');
    expect(target, findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton && widget.tooltip == 'Show threat',
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('connection arriving after unmount is disposed', (tester) async {
    final created = Completer<EngineConnection?>();
    StockfishConnectionFactory.createForTest = () => created.future;
    await tester.pumpWidget(harness(active: true));
    InlineEngineBar.toggleEngine();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    final connection = _Connection();
    created.complete(connection);
    await tester.pump();
    expect(connection.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });
}
