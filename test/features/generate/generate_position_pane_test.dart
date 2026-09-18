import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/app/engine_runtime.dart';
import '../../support/runtime_settings.dart';
import '../../support/generation_artifacts_fixture.dart';
import '../../support/generation_publication_fixture.dart';
import 'dart:async';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/generation_session_controller.dart';
import 'package:chess_auto_prep/features/generate/widgets/generate_position_pane.dart';
import 'package:chess_auto_prep/services/eval/db_move_list.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

RuntimeSettings? _engineFixtureSettings;
EngineRuntime get engines =>
    testEngines(_engineFixtureSettings ??= testRuntimeSettings());
void main() {
  setUp(() {
    _engineFixtureSettings = null;
    addTearDown(() => _engineFixtureSettings?.dispose());
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'settings stay in the overlay and apply to both generation actions',
    (tester) async {
      final gen = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: JobManager(),
        enginePool: engines.pool,
        engineLifecycle: engines.lifecycle,
        artifacts: generationArtifactsFixture(),
        publication: generationPublicationFixture(),
      );
      addTearDown(gen.dispose);
      final calls = <({String? san, int depth, int cores})>[];
      final coverageCalls = <(int, double)>[];
      String? played;
      var booksOpened = 0;
      await pumpRuntimeWidget(
        tester,
        _engineFixtureSettings ??= testRuntimeSettings(),
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: GeneratePositionPane(
                fen: kStandardStartFen,
                databaseName: 'My book / Main',
                generation: gen,
                onGenerate:
                    ({
                      String? moveSan,
                      required int plies,
                      required int cores,
                      required int engineMoves,
                      required double maiaCoverage,
                    }) async {
                      calls.add((san: moveSan, depth: plies, cores: cores));
                      coverageCalls.add((engineMoves, maiaCoverage));
                      return null;
                    },
                onPlayMove: (san) => played = san,
                onPlanLines: () {},
                onBuildChessDb: () => booksOpened++,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Depth (half-moves)'), findsNothing);
      expect(find.text('Expected'), findsNothing);
      expect(find.text('Continuation'), findsOneWidget);
      expect(find.text('My book / Main'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('generation-actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('build-chessdb-repertoire')));
      await tester.pumpAndSettle();
      expect(booksOpened, 1);
      expect(calls, isEmpty);
      expect(find.text('—'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('generation-settings')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('generate-engine-moves')),
          matching: find.byTooltip('More'),
        ),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('generate-maia-coverage')),
          matching: find.byTooltip('More'),
        ),
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('generate-depth')),
          matching: find.byType(TextField),
        ),
        '3',
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('generate-cores')),
          matching: find.byType(TextField),
        ),
        '1',
      );
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Depth (half-moves)'), findsNothing);
      await tester.tap(find.text('Generate'));
      await tester.pump();
      expect(calls.single, (san: null, depth: 3, cores: 1));
      expect(coverageCalls.single, (5, .65));
      await tester.tap(find.byTooltip('Evaluate Na3 and save engine PV'));
      await tester.pump();
      expect(calls.last, (san: 'Na3', depth: 3, cores: 1));
      await tester.tap(find.text('Na3'));
      expect(played, 'Na3');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('generation-settings')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('generate-depth')),
          matching: find.byType(TextField),
        ),
        '0',
      );
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generate'));
      await tester.pumpAndSettle();
      expect(calls.last, (san: null, depth: 1, cores: 1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('position_generation.plies'), 1);
      expect(prefs.getInt('position_generation.engineMoves'), 5);
      expect(prefs.getInt('position_generation.maiaCoverage'), 65);
    },
  );
  testWidgets('late ChessDB results cannot populate a different position', (
    tester,
  ) async {
    final gen = GenerationSessionController(
      databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
      jobs: JobManager(),
      enginePool: engines.pool,
      engineLifecycle: engines.lifecycle,
      artifacts: generationArtifactsFixture(),
      publication: generationPublicationFixture(),
    );
    addTearDown(gen.dispose);
    final pending = <String, Completer<DbMoveList>>{};
    Future<DbMoveList> lookup(String fen) =>
        (pending[fen] = Completer()).future;
    Widget pane(String fen) => MaterialApp(
      home: Scaffold(
        body: GeneratePositionPane(
          fen: fen,
          databaseName: 'Main',
          generation: gen,
          lookupChessDb: lookup,
          onGenerate:
              ({
                String? moveSan,
                required int plies,
                required int cores,
                required int engineMoves,
                required double maiaCoverage,
              }) async => null,
          onPlayMove: (_) {},
          onPlanLines: () {},
        ),
      ),
    );
    await pumpRuntimeWidget(
      tester,
      _engineFixtureSettings ??= testRuntimeSettings(),
      pane(kStandardStartFen),
    );
    await tester.tap(find.byKey(const ValueKey('evaluation-source')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ChessDB'));
    await tester.pump();
    final next = playUciMove(kStandardStartFen, 'e2e4')!;
    await pumpRuntimeWidget(
      tester,
      _engineFixtureSettings ??= testRuntimeSettings(),
      pane(next),
    );
    pending[kStandardStartFen]!.complete(
      const DbMoveList(
        source: DbMoveSource.chessDbApi,
        moves: [DbMove(uci: 'e2e4', stmCp: 1234)],
      ),
    );
    pending[next]!.complete(
      const DbMoveList(
        source: DbMoveSource.chessDbApi,
        moves: [DbMove(uci: 'a7a6', stmCp: 25)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('+12.34'), findsNothing);
    expect(find.text('-0.25'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('shared source control handles switching and generation', (
    tester,
  ) async {
    final gen = GenerationSessionController(
      databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
      jobs: JobManager(),
      enginePool: engines.pool,
      engineLifecycle: engines.lifecycle,
      artifacts: generationArtifactsFixture(),
      publication: generationPublicationFixture(),
    );
    addTearDown(gen.dispose);
    final requests = <Completer<DbMoveList>>[];
    var chessDb = true;
    var generated = 0;
    late StateSetter update;
    await pumpRuntimeWidget(
      tester,
      _engineFixtureSettings ??= testRuntimeSettings(),
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return GeneratePositionPane(
                fen: kStandardStartFen,
                databaseName: 'Main',
                generation: gen,
                sourceControl: Text(
                  chessDb ? 'Shared ChessDB' : 'Shared generated',
                ),
                chessDbSource: chessDb,
                onShowGenerated: () => setState(() => chessDb = false),
                lookupChessDb: (_) {
                  final request = Completer<DbMoveList>();
                  requests.add(request);
                  return request.future;
                },
                onGenerate:
                    ({
                      String? moveSan,
                      required int plies,
                      required int cores,
                      required int engineMoves,
                      required double maiaCoverage,
                    }) async {
                      generated++;
                      return null;
                    },
                onPlayMove: (_) {},
                onPlanLines: () {},
              );
            },
          ),
        ),
      ),
    );
    expect(requests, hasLength(1));
    expect(find.byKey(const ValueKey('evaluation-source')), findsNothing);
    update(() => chessDb = false);
    await tester.pump();
    requests.first.complete(
      const DbMoveList(
        source: DbMoveSource.chessDbApi,
        moves: [DbMove(uci: 'e2e4', stmCp: 1234)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('+12.34'), findsNothing);
    update(() => chessDb = true);
    await tester.pump();
    expect(requests, hasLength(2));
    requests.last.complete(
      const DbMoveList(
        source: DbMoveSource.chessDbApi,
        moves: [DbMove(uci: 'e2e4', stmCp: 25)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('+0.25'), findsOneWidget);
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();
    expect(chessDb, isFalse);
    expect(generated, 1);
    expect(find.text('Shared generated'), findsOneWidget);
    expect(find.text('+0.25'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
