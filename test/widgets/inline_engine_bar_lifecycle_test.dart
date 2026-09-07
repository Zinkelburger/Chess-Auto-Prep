import 'dart:async';

import 'package:chess_auto_prep/services/engine/engine_connection.dart';
import 'package:chess_auto_prep/services/engine/stockfish_connection_factory.dart';
import 'package:chess_auto_prep/widgets/engine/inline_engine_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Connection implements EngineConnection {
  final output = StreamController<String>.broadcast();
  final closed = Completer<void>();
  bool disposed = false;
  @override
  Stream<String> get stdout => output.stream;
  @override
  Future<void> get done => closed.future;
  @override
  Future<void> waitForReady() async {}
  @override
  void sendCommand(String command) {
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
