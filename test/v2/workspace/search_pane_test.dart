import 'package:chess_auto_prep/v2/chess/pgn/analysis_board.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/v2/workspace/fill_gaps.dart';
import 'package:chess_auto_prep/v2/workspace/search_pane.dart';
import 'package:chessground/chessground.dart' show StaticChessboard;
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chess/generation/scripted_sources.dart';
import '../support/scripted_engine.dart';
import '../support/session_fixture.dart';

/// White king and pawn against a bare king: few moves, so a run is small.
const kingAndPawn = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';

void main() {
  late SessionFixture fixture;
  late EngineAnalysis analysis;
  late SettingsStore settings;
  late FillGaps fill;

  setUp(() async {
    fixture = await openSession('[Event "x"]\n[Result "*"]\n\n*\n');
    analysis = EngineAnalysis(
      fixture.session,
      () async => Started(ScriptedEngine()),
    );
    settings = SettingsStore();
    await fixture.session.showAnalysisBoard(
      analysisBoard(side: Side.white, root: const Fen(kingAndPawn)),
    );
    final root = positionOf(kingAndPawn);
    final afterE4 = afterUci(root, 'e2e4');
    fill = FillGaps(
      session: fixture.session,
      analysis: analysis,
      documents: fixture.store,
      tools: (_) async => FillReady(
        evaluator: ScriptedEvaluator(
          scores: {
            // e4 is a pawn better than anything else for White; after it,
            // Kf7 is played three games in ten and gives White two pawns.
            afterE4.fen: -100,
            afterUci(afterE4, 'e8f7').fen: 200,
          },
        ),
        policy: const ScriptedPolicy({'e8d8': 0.7, 'e8f7': 0.3}),
        release: () async {},
      ),
    );
  });

  tearDown(() {
    fill.dispose();
    settings.dispose();
    analysis.dispose();
    fixture.dispose();
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: darkTheme(),
      home: Scaffold(
        body: SizedBox(
          width: 560,
          height: 480,
          child: SearchPane(
            fill: fill,
            session: fixture.session,
            settings: settings,
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'a tree that cannot be saved does not hold the tab back',
    (tester) async {
      fill.dispose();
      fixture.externalEdit(
        '// Color: White\n[Event "Main"]\n[Result "*"]\n[FEN "$kingAndPawn"]\n[SetUp "1"]\n\n1. e4 *',
      );
      await fixture.session.open(fixture.ref);
      final published = <String>[];
      fill = FillGaps(
        session: fixture.session,
        analysis: analysis,
        documents: fixture.store,
        tools: (_) async => FillReady(
          evaluator: ScriptedEvaluator(),
          policy: const ScriptedPolicy({'e8d8': 1}),
          release: () async {},
        ),
        keepTree: (_, text, {required runId}) async {
          published.add(runId);
          throw StateError('test storage unavailable');
        },
      );
      await pump(tester);
      await tester.runAsync(
        () => fill.start(const FillRequest(elo: 2200, depthPlies: 2)),
      );
      await tester.pump();
      expect(fill.state, isA<FillDone>());
      expect(fill.canMakeLines, isTrue);
      expect(find.textContaining('Retry'), findsNothing);
      expect(published, hasLength(1));
    },
  );

  testWidgets('before a search: its two numbers and one button', (
    tester,
  ) async {
    await pump(tester);
    expect(find.widgetWithText(TextField, 'Opponent'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Depth'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Skip under 1 in'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Search'), findsOneWidget);
    expect(find.textContaining('until you stop it'), findsOneWidget);
  });

  /// Runs a search two plies deep from the board, on real time.
  Future<void> searched(WidgetTester tester) async {
    await pump(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Depth'), '2');
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Search'));
      while (!fill.running) {
        await Future<void>.delayed(Duration.zero);
      }
      while (fill.running) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('the board floated over a move goes when the board moves on '
      'under the still pointer', (tester) async {
    await searched(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('e4')));
    await tester.pump(previewDelay);
    expect(find.byType(StaticChessboard), findsOneWidget);
    fixture.session.playMove('e2e4');
    await tester.pump();
    expect(find.text('Their reply'), findsOneWidget, reason: 'other rows');
    expect(find.byType(StaticChessboard), findsNothing);
  });

  testWidgets('the values at the board, following it: every move of ours, '
      'then their replies most played first with the trap marked', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Depth'), '2');
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Search'));
      // Let the run finish on real time.
      while (!fill.running) {
        await Future<void>.delayed(Duration.zero);
      }
      while (fill.running) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pumpAndSettle();
    expect(fill.depth, 2);
    expect(find.text('Your move'), findsOneWidget);
    expect(find.text('Expectimax'), findsOneWidget);
    // Nothing is pruned: a move the engine thinks little of is searched too.
    expect(find.text('e4'), findsOneWidget);
    expect(find.text('e3'), findsOneWidget);
    await tester.tap(find.text('e4'));
    await tester.pumpAndSettle();
    expect(fixture.session.currentMove?.san, 'e4');
    expect(find.text('Their reply'), findsOneWidget);
    expect(find.text('Played'), findsOneWidget);
    expect(find.text('Kd8'), findsOneWidget);
    expect(find.text('Kf7?'), findsOneWidget, reason: 'a trap');
    expect(find.text('70%'), findsOneWidget);
    expect(find.text('30%'), findsOneWidget);
    // Off the search: another root.
    await fixture.session.showAnalysisBoard(
      analysisBoard(side: Side.white, root: Fen.initial),
    );
    await tester.pumpAndSettle();
    expect(find.text('This position is not in the search.'), findsOneWidget);
    // Nothing to make lines of on the analysis board.
    expect(find.text('Make lines'), findsNothing);
  });
}
