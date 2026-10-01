import 'dart:async';

import 'package:chess_auto_prep/chess/pgn/analysis_board.dart';
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/fill_gaps.dart';
import 'package:chess_auto_prep/workspace/fill_states.dart';
import 'package:chess_auto_prep/workspace/search_pane.dart';
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

/// Shows the search settings folded under Settings.
Future<void> unfold(WidgetTester tester) async {
  await tester.tap(find.text('Settings'));
  await tester.pump();
}

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
      jobs: EngineJobs(analysis),
      documents: fixture.store,
      tools: (_) async => FillReady(
        evaluator: ScriptedEvaluator(
          depth: 22,
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

  testWidgets('a failed tree save offers retry and explicit discard', (
    tester,
  ) async {
    fill.dispose();
    fixture.externalEdit(
      '// Color: White\n[Event "Main"]\n[Result "*"]\n[FEN "$kingAndPawn"]\n[SetUp "1"]\n\n1. e4 *',
    );
    await fixture.session.open(fixture.ref);
    final published = <String>[];
    fill = FillGaps(
      session: fixture.session,
      jobs: EngineJobs(analysis),
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
    expect(find.text('Retry saving tree'), findsOneWidget);
    expect(fill.canStart, isFalse);
    await tester.tap(find.text('Discard tree save'));
    await tester.pump();
    expect(fill.canStart, isTrue);
    expect(published, hasLength(1));
  });

  testWidgets('a run the model stops says so after its depth and positions', (
    tester,
  ) async {
    fill.dispose();
    fill = FillGaps(
      session: fixture.session,
      jobs: EngineJobs(analysis),
      documents: fixture.store,
      tools: (_) async => FillReady(
        evaluator: ScriptedEvaluator(),
        policy: const AbsentPolicy(),
        release: () async {},
      ),
      keepTree: (_, _, {required runId}) async {},
    );
    await pump(tester);
    await tester.runAsync(
      () => fill.start(const FillRequest(elo: 2200, depthPlies: 2)),
    );
    await tester.pump();
    final status = find.textContaining('the opponent model could not answer');
    expect(status, findsOneWidget);
    final words = tester.widget<Text>(status).data!;
    expect(words, startsWith('Stopped at depth '));
    expect(words, isNot(contains('Resume')));
    expect(words, isNot(contains('rated')));
    expect(find.widgetWithText(FilledButton, 'Resume expectimax'), findsOne);
  });

  testWidgets('both pause controls explain when they stop and keep the run', (
    tester,
  ) async {
    fill.dispose();
    final tools = Completer<FillToolsResult>();
    fill = FillGaps(
      session: fixture.session,
      jobs: EngineJobs(analysis),
      documents: fixture.store,
      tools: (_) => tools.future,
    );
    await pump(tester);
    final run = fill.start(const FillRequest(elo: 2200));
    await tester.pump();
    expect(find.byIcon(Icons.pause), findsNWidgets(2));
    await tester.tap(find.text('Stop after finishing depth 1'));
    await tester.pump();
    expect((fill.state as FillRunning).lastPly, 1);
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect((fill.state as FillRunning).finishing, isTrue);
    tools.complete(
      FillReady(
        evaluator: ScriptedEvaluator(),
        policy: const ScriptedPolicy({'e8d8': 1}),
        release: () async {},
      ),
    );
    await tester.runAsync(() => run);
    await tester.pump();
    expect(fill.running, isFalse);
  });

  testWidgets('settings are editable directly above the search', (
    tester,
  ) async {
    await pump(tester);
    expect(
      find.widgetWithText(TextField, 'Depth'),
      findsNothing,
      reason: 'folded under Settings',
    );
    await unfold(tester);
    for (final label in [
      'Engine depth',
      'Maia rating',
      'Candidates',
      'Depth',
      '1 in N games',
    ]) {
      expect(find.widgetWithText(TextField, label), findsOneWidget);
    }
    await tester.enterText(
      find.widgetWithText(TextField, 'Maia rating'),
      '1800',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Candidates'), '2');
    await tester.enterText(
      find.widgetWithText(TextField, '1 in N games'),
      '50',
    );
    await tester.pump();
    expect(settings.value.opponentElo, 1800);
    expect(fill.candidateMoves, 2);
    expect(fill.replyFloor, 0.02);
    await tester.enterText(find.widgetWithText(TextField, 'Candidates'), '0');
    await tester.tap(find.widgetWithText(FilledButton, 'Expectimax'));
    await tester.pump();
    expect(fill.running, isFalse);
    expect(find.text('Candidates: 1 to 218'), findsOneWidget);
  });

  /// Runs a search two plies deep from the board, on real time.
  Future<void> searched(WidgetTester tester) async {
    await pump(tester);
    await unfold(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Depth'), '2');
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Expectimax'));
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
    await unfold(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Depth'), '2');
    await tester.enterText(find.widgetWithText(TextField, 'Root moves'), '6');
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Expectimax'));
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
    expect(fill.rootMoves, 6);
    expect(find.text('Your move'), findsOneWidget);
    // Depth is on the Engine value's hover, not a column of its own.
    expect(find.byTooltip('Depth 22'), findsWidgets);
    expect(find.text('22'), findsNothing);
    expect(find.text('Expectimax'), findsOneWidget, reason: 'the column');
    expect(
      find.widgetWithText(FilledButton, 'Resume expectimax'),
      findsOneWidget,
      reason: 'the search covers the board',
    );
    // Six root moves keep every legal move, weak ones included.
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
    expect(
      find.text('No saved results here yet. Start Expectimax from this board.'),
      findsOneWidget,
    );
    // Nothing to make lines of on the analysis board.
    expect(find.text('Make lines'), findsNothing);
  });
}
