import 'package:chess_auto_prep/v2/engines/engine_line.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/v2/workspace/engine_pane.dart';
import 'package:chessground/chessground.dart' show StaticChessboard;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';
import '../support/scripted_engine.dart';

void main() {
  late SessionFixture fixture;
  late DocumentSession session;
  late ScriptedEngine engine;
  late EngineAnalysis analysis;

  setUp(() async {
    fixture = await openSession(blackChapter);
    session = fixture.session;
    engine = ScriptedEngine();
    analysis = EngineAnalysis(session, () async => Started(engine));
  });

  tearDown(() {
    analysis.dispose();
    fixture.dispose();
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: darkTheme(),
      home: Scaffold(
        body: Column(
          children: [EnginePane(session: session, analysis: analysis)],
        ),
      ),
    ),
  );

  /// Switches the engine on and gives it the Sicilian as its best line.
  Future<void> analyse(WidgetTester tester) async {
    await pump(tester);
    await analysis.enable();
    await tester.pump();
    engine.current.emit(
      line(score: const Centipawns(-35), depth: 18, pv: ['c7c5', 'g1f3']),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('starting the engine reveals the compact header and lines', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Engine'), findsNothing);
    await analysis.enable();
    await tester.pump();
    expect(find.text('Scripted 1'), findsOneWidget);
    engine.current.emit(
      line(score: const Centipawns(-35), depth: 18, pv: ['c7c5', 'g1f3']),
    );
    engine.current.emit(
      line(multiPv: 2, score: const MateIn(-2), pv: ['e7e5']),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // Black to move, so the engine's -0.35 is +0.35 for White. The score
    // is read in the row's gutter and nowhere larger.
    expect(find.text('+0.35'), findsOneWidget);
    expect(find.text('Depth 18 · Scripted 1'), findsOneWidget);
    expect(find.text('1... c5'), findsOneWidget);
    expect(find.text('2. Nf3'), findsOneWidget);
    expect(find.text('#2'), findsOneWidget);
    expect(find.text('1... e5'), findsOneWidget);
  });

  testWidgets('off, the pane collapses; on, every row keeps its height '
      'before and after it has a line', (tester) async {
    await pump(tester);
    expect(tester.getSize(find.byType(EnginePane)).height, 0);
    await analysis.enable();
    await tester.pump();
    final before = tester.getSize(find.byType(EnginePane));
    expect(before.height, engineBarHeight + engineRowHeight * 3);
    engine.current.emit(
      line(score: const Centipawns(-35), depth: 18, pv: ['c7c5', 'g1f3']),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getSize(find.byType(EnginePane)), before);
    await tester.tap(find.byTooltip('Turn engine off (E)'));
    await tester.pump();
    expect(tester.getSize(find.byType(EnginePane)).height, 0);
    expect(analysis.enabled, isFalse);
  });

  testWidgets('a tick without the best line promotes no other line', (
    tester,
  ) async {
    await pump(tester);
    await analysis.enable();
    await tester.pump();
    engine.current.emit(
      line(multiPv: 2, score: const Centipawns(-35), depth: 18, pv: ['e7e5']),
    );
    engine.current.emit(
      line(multiPv: 3, score: const Centipawns(-50), depth: 18, pv: ['g8f6']),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Scripted 1'), findsOneWidget, reason: 'no depth yet');
    expect(find.text('+0.35'), findsOneWidget);
    expect(find.text('1... e5'), findsOneWidget);
    expect(find.text('1... Nf6'), findsOneWidget);
    engine.current.emit(
      line(score: const Centipawns(-20), depth: 18, pv: ['c7c5']),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Depth 18 · Scripted 1'), findsOneWidget);
    expect(find.text('+0.20'), findsOneWidget);
  });

  testWidgets('resting the pointer on a move floats the position after it', (
    tester,
  ) async {
    await analyse(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('2. Nf3')));
    await tester.pump();
    expect(find.byType(StaticChessboard), findsNothing, reason: 'not yet');
    await tester.pump(previewDelay);
    final board = tester.widget<StaticChessboard>(
      find.byType(StaticChessboard),
    );
    expect(board.fen, startsWith('rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/'));
    expect(board.lastMove?.uci, 'g1f3');
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(find.byType(StaticChessboard), findsNothing);
  });

  testWidgets('the floated board goes with its row: a deeper line keeps it, '
      'a move on the board under the still pointer takes it away', (
    tester,
  ) async {
    await analyse(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('2. Nf3')));
    await tester.pump(previewDelay);
    expect(find.byType(StaticChessboard), findsOneWidget);
    engine.current.emit(
      line(score: const Centipawns(-30), depth: 19, pv: ['c7c5', 'g1f3']),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(StaticChessboard), findsOneWidget, reason: 'deeper');
    session.forward();
    await tester.pump();
    expect(find.byType(StaticChessboard), findsNothing);
  });

  testWidgets('clicking a move plays the line up to it', (tester) async {
    await analyse(tester);
    await tester.tap(find.text('2. Nf3'));
    await tester.pump();
    expect(session.currentMove?.uci, 'g1f3');
    expect(session.cursor.parent, isNot(session.cursor));
    // 1... c5 2. Nf3 is the chapter's own line, so following it wrote
    // nothing.
    expect(fixture.onDisk, blackChapter);
  });

  testWidgets('a failure is written where the name was', (tester) async {
    analysis.dispose();
    analysis = EngineAnalysis(
      session,
      () async => const StartFailed('No Stockfish in this build'),
    );
    await pump(tester);
    await analysis.enable();
    await tester.pump();
    expect(find.text('No Stockfish in this build'), findsOneWidget);
    expect(find.byTooltip('Retry engine (E)'), findsOneWidget);
  });
}
