import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/engines/engine_line.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/v2/workspace/engine_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_engine.dart';

void main() {
  late DocumentSession session;
  late ScriptedEngine engine;
  late EngineAnalysis analysis;

  setUp(() {
    session = DocumentSession()
      ..open(parseChapter(name: 'Main', text: blackChapter));
    engine = ScriptedEngine();
    analysis = EngineAnalysis(session, () async => Started(engine));
  });

  tearDown(() {
    analysis.dispose();
    session.dispose();
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: darkTheme(),
      home: Scaffold(body: EnginePane(analysis: analysis)),
    ),
  );

  testWidgets('the switch starts the engine and the lines fill in', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Engine off'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.text('Scripted 1'), findsOneWidget);
    engine.current.emit(
      line(score: const Centipawns(-35), depth: 18, pv: ['c7c5', 'g1f3']),
    );
    engine.current.emit(
      line(multiPv: 2, score: const MateIn(-2), pv: ['e7e5']),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // Black to move, so the engine's -0.35 is +0.35 for White.
    expect(find.text('+0.35'), findsNWidgets(2), reason: 'headline and row');
    expect(find.text('depth 18 · Scripted 1'), findsOneWidget);
    expect(find.text('1... c5 2. Nf3'), findsOneWidget);
    expect(find.text('#2'), findsOneWidget);
    expect(find.text('1... e5'), findsOneWidget);
  });

  testWidgets('a tick without the best line promotes no other line', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    engine.current.emit(
      line(multiPv: 2, score: const Centipawns(-35), depth: 18, pv: ['e7e5']),
    );
    engine.current.emit(
      line(multiPv: 3, score: const Centipawns(-50), depth: 18, pv: ['g8f6']),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Scripted 1'), findsOneWidget, reason: 'no depth yet');
    expect(find.text('+0.35'), findsOneWidget, reason: 'the row, not above');
    expect(find.text('1... e5'), findsOneWidget);
    expect(find.text('1... Nf6'), findsOneWidget);
    engine.current.emit(
      line(score: const Centipawns(-20), depth: 18, pv: ['c7c5']),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('depth 18 · Scripted 1'), findsOneWidget);
    expect(find.text('+0.20'), findsNWidgets(2));
  });

  testWidgets('a failure is written where the name was', (tester) async {
    analysis.dispose();
    analysis = EngineAnalysis(
      session,
      () async => const StartFailed('No Stockfish in this build'),
    );
    await pump(tester);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.text('No Stockfish in this build'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });
}
