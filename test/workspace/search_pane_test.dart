import 'dart:async';

import 'package:chess_auto_prep/chess/pgn/analysis_board.dart';
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/evaluation_source.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/fill_gaps.dart';
import 'package:chess_auto_prep/workspace/fill_states.dart';
import 'package:chess_auto_prep/workspace/search_pane.dart';
import 'package:chess_auto_prep/workspace/search_settings.dart';
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
    expect(find.widgetWithText(FilledButton, 'Resume'), findsOne);
  });

  testWidgets('the one button pauses; the status line lets the depth finish', (
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
    final button = tester.getRect(find.byType(FilledButton));
    expect(find.byIcon(Icons.pause), findsOneWidget);
    await tester.tap(find.text('Finish depth 1'));
    await tester.pump();
    expect((fill.state as FillRunning).lastPly, 1);
    expect(find.text('Finish depth 1'), findsNothing);
    expect(find.textContaining('Pausing after depth 1'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Pause'));
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
    expect(
      tester.getRect(find.byType(FilledButton)),
      button,
      reason: 'the button is where it was, the size it was',
    );
  });

  /// The box at the end of the gear's row called [name].
  Finder box(String name) => find.descendant(
    of: find.widgetWithText(Row, name),
    matching: find.byType(TextField),
  );

  testWidgets('only the button, the depth and the gear head the tab; the '
      'gear swaps the results for the settings and writes them', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byType(TextField), findsOneWidget, reason: 'the depth');
    expect(find.text('For White · Maia 2200 · best 4, then 4'), findsOne);
    await tester.tap(find.byTooltip('Expectimax settings'));
    await tester.pump();
    for (final name in [
      'Maia rating',
      'First move',
      'Later moves',
      'Search replies met once in',
      'Engine depth',
      'Evaluation',
    ]) {
      expect(find.text(name), findsOneWidget);
    }
    final rows = find
        .descendant(
          of: find.byType(SearchSettingsView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.enterText(box('Maia rating'), '1800');
    await tester.enterText(box('Later moves'), '2');
    await tester.enterText(box('Search replies met once in'), '50');
    await tester.scrollUntilVisible(
      find.text('ChessDB'),
      100,
      scrollable: rows,
    );
    await tester.tap(find.text('ChessDB'));
    await tester.pump();
    expect(settings.value.opponentElo, 1800);
    expect(settings.value.expectimax.candidateMoves, 2);
    expect(FillRequest.of(settings.value).replyFloor, 0.02);
    expect(settings.value.expectimax.source, EvaluationSource.chessDb);
    expect(
      find.text('For White · Maia 1800 · best 4, then 2 · ChessDB + Stockfish'),
      findsOne,
    );
    // A number out of range is said, not taken, and nothing starts on it.
    await tester.scrollUntilVisible(
      find.text('Later moves'),
      -100,
      scrollable: rows,
    );
    await tester.enterText(box('Later moves'), '0');
    await tester.pump();
    expect(find.text('Later moves: 1 to 218'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Expectimax'));
    await tester.pump();
    expect(fill.running, isFalse);
    expect(settings.value.expectimax.candidateMoves, 2);
    // Closing the gear puts the number back and gives the results back.
    await tester.tap(find.byTooltip('Show results'));
    await tester.pump();
    expect(find.text('Later moves'), findsNothing);
    expect(find.text('Later moves: 1 to 218'), findsNothing);
  });

  testWidgets('the ChessDB mainline keeps only its depth; a running search '
      'shows the settings without letting them change', (tester) async {
    fill.dispose();
    final tools = Completer<FillToolsResult>();
    fill = FillGaps(
      session: fixture.session,
      jobs: EngineJobs(analysis),
      documents: fixture.store,
      tools: (_) => tools.future,
    );
    await pump(tester);
    await tester.tap(find.byTooltip('Expectimax settings'));
    await tester.pump();
    await tester.tap(find.text('ChessDB mainline'));
    await tester.pump();
    expect(settings.value.expectimax.method, SearchMethod.mainline);
    expect(find.text('Maia rating'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Build'), findsOneWidget);
    await tester.tap(find.text('Maia practical'));
    await tester.pump();
    final run = fill.start(FillRequest.of(settings.value));
    await tester.pump();
    expect(find.text('Pause the search to change these.'), findsOneWidget);
    await tester.tap(find.text('ChessDB mainline'));
    await tester.pump();
    expect(settings.value.expectimax.method, SearchMethod.practical);
    fill.finish();
    tools.complete(
      FillReady(
        evaluator: ScriptedEvaluator(),
        policy: const ScriptedPolicy({'e8d8': 1}),
        release: () async {},
      ),
    );
    await tester.runAsync(() => run);
    await tester.pump();
    expect(find.text('Pause the search to change these.'), findsNothing);
  });

  testWidgets('the bar fits a pane at its narrowest', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 480,
              child: SearchPane(
                fill: fill,
                session: fixture.session,
                settings: settings,
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Expectimax settings'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  /// Runs a search two plies deep from the board, on real time.
  Future<void> searched(WidgetTester tester) async {
    await pump(tester);
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
    await tester.enterText(find.widgetWithText(TextField, 'Depth'), '2');
    await settings.update(
      settings.value.copyWith(
        expectimax: settings.value.expectimax.copyWith(rootMoves: 6),
      ),
    );
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
    expect(settings.value.expectimax.depth, 2);
    expect(find.text('Your move'), findsOneWidget);
    // Depth is on the Engine value's hover, not a column of its own.
    expect(find.byTooltip('Depth 22'), findsWidgets);
    expect(find.text('22'), findsNothing);
    expect(find.text('Expectimax'), findsOneWidget, reason: 'the column');
    expect(
      find.widgetWithText(FilledButton, 'Resume'),
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
