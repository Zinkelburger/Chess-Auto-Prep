import 'dart:io';
import 'dart:ui' as ui;

import 'package:chess_auto_prep/app/builder_lifetime.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/generation_session_types.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/screens/repertoire_screen.dart';
import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/widgets/repertoire_generation_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'helpers/board_helpers.dart';
import 'helpers/tactics_helpers.dart';

Future<void> _ready(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 120 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsOneWidget);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _captureRejection() async {
  final view = RendererBinding.instance.renderViews.first;
  final layer = view.debugLayer;
  expect(layer, isA<OffsetLayer>());
  final ratio = view.flutterView.devicePixelRatio;
  final image = await (layer as OffsetLayer).toImage(
    Offset.zero & Size(view.size.width * ratio, view.size.height * ratio),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  expect(bytes, isNotNull);
  await File(
    '/tmp/renewal-generation-source-rejected.png',
  ).writeAsBytes(bytes!.buffer.asUint8List());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Build rejects changed and ABA sources without creating a job',
    (tester) async {
      final root = await AppPaths.repertoiresDirectory();
      final folder = await Directory(
        p.join(root.path, 'Admission ${DateTime.now().microsecondsSinceEpoch}'),
      ).create(recursive: true);
      addTearDown(() => folder.delete(recursive: true));
      final source = File(p.join(folder.path, 'Original.pgn'));
      final other = File(p.join(folder.path, 'Other.pgn'));
      const originalPgn =
          '// Color: White\n\n[Event "Original line"]\n[Result "*"]\n\n'
          '1. e4 e5 2. Nf3 Nc6 *\n';
      const otherPgn =
          '// Color: White\n\n[Event "Other line"]\n[Result "*"]\n\n'
          '1. d4 d5 2. c4 e6 *\n';
      await source.writeAsString(originalPgn);
      await other.writeAsString(otherPgn);
      await pumpApp(tester);
      getAppState(tester).switchToBuilder(repertoirePath: source.path);
      await _ready(tester, find.text('Original line'));
      final document = tester
          .element(find.byType(RepertoireScreen))
          .read<BuilderLifetime>()
          .workspace
          .document;
      final original = document.currentRepertoire!;

      await tester.tap(find.text('Actions'));
      await _ready(tester, find.text('Generate from here…').hitTestable());
      await tester.tap(find.text('Generate from here…'));
      final actions = find.byKey(const ValueKey('generation-actions'));
      await _ready(tester, actions.hitTestable());
      await tester.tap(actions);
      final build = find.byKey(const ValueKey('build-chessdb-repertoire'));
      await _ready(tester, build.hitTestable());
      await tester.tap(build);
      final start = find.text('Generate Repertoire').hitTestable();
      await _ready(tester, start);
      final label = AppLocalizations.of(
        tester.element(find.byType(RepertoireGenerationTab)),
      ).generationSourceChanged;
      final jobsBefore = JobManager.instance.jobs;

      // This is the real document transition a delayed chapter-creation
      // completion can make behind configuration. Controlled widget tests
      // separately exercise the delayed catalog callback itself.
      for (final target in [
        RepertoireMetadata(
          filePath: other.path,
          name: 'Other',
          lastModified: DateTime.now(),
        ),
        original,
      ]) {
        await document.setRepertoire(target);
        await tester.pump(const Duration(milliseconds: 300));
        expect(document.currentRepertoire?.filePath, target.filePath);
        expect(document.isLoading, isFalse);
        final configuration = tester.widget<RepertoireGenerationTab>(
          find.byType(RepertoireGenerationTab),
        );
        expect(configuration.currentRepertoire?.filePath, source.path);
        await tester.tap(start);
        await _ready(tester, find.text(label));
        expect(configuration.generationController.isGenerating, isFalse);
        expect(JobManager.instance.jobs, jobsBefore);
        expect(await source.readAsString(), originalPgn);
        expect(await other.readAsString(), otherPgn);
        if (target.filePath == other.path) await _captureRejection();
        // Dismiss the first message so the ABA assertion requires a new one.
        ScaffoldMessenger.of(
          tester.element(find.byType(RepertoireGenerationTab)),
        ).removeCurrentSnackBar();
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.tap(find.byTooltip('Close'));
      await _ready(tester, actions.hitTestable());
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'native Build publishes an admitted completed tree and refreshes the open chapter',
    (tester) async {
      final root = await AppPaths.repertoiresDirectory();
      final folder = await Directory(
        p.join(
          root.path,
          'Publication ${DateTime.now().microsecondsSinceEpoch}',
        ),
      ).create(recursive: true);
      addTearDown(() => folder.delete(recursive: true));
      final source = File(p.join(folder.path, 'Original.pgn'));
      const originalPgn =
          '// Color: White\n\n[Event "Retained d4 line"]\n[Result "*"]\n\n'
          '1. d4 *\n';
      await source.writeAsString(originalPgn);
      await pumpApp(tester);
      getAppState(tester).switchToBuilder(repertoirePath: source.path);
      await _ready(tester, find.text('Retained d4 line'));
      final document = tester
          .element(find.byType(RepertoireScreen))
          .read<BuilderLifetime>()
          .workspace
          .document;
      expect(document.repertoireLines.map((line) => line.moves), [
        ['d4'],
      ]);
      final beforeRevision = document.sourceRevision;

      await tester.tap(find.text('Actions'));
      await _ready(tester, find.text('Generate from here…').hitTestable());
      await tester.tap(find.text('Generate from here…'));
      final actions = find.byKey(const ValueKey('generation-actions'));
      await _ready(tester, actions.hitTestable());
      await tester.tap(actions);
      final build = find.byKey(const ValueKey('build-chessdb-repertoire'));
      await _ready(tester, build.hitTestable());
      await tester.tap(build);
      await _ready(tester, find.text('Generate Repertoire').hitTestable());
      final configuration = tester.widget<RepertoireGenerationTab>(
        find.byType(RepertoireGenerationTab),
      );
      final receiver = configuration.createPublicationReceiver();
      expect(receiver, isNotNull);
      final controller = configuration.generationController;
      final jobsBefore = JobManager.instance.jobs.toSet();

      // Exercise native staging, source commit, and the route's actual receipt
      // adoption without a network build or enrichment probe. The complete
      // one-ply tree follows the same resumed-tree path as the pipeline tests.
      final treeRoot = BuildTreeNode(
        fen: kStandardStartFen,
        moveSan: '',
        moveUci: '',
        ply: 0,
        isWhiteToMove: true,
        nodeId: 0,
      )..engineEvalCp = 20;
      treeRoot.children.add(
        BuildTreeNode(
          fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
          moveSan: 'e4',
          moveUci: 'e2e4',
          ply: 1,
          isWhiteToMove: false,
          nodeId: 1,
          parent: treeRoot,
        )..engineEvalCp = -20,
      );
      final tree = BuildTree(
        root: treeRoot,
        maxPlyReached: 1,
        buildComplete: true,
      )..computeMetadata();
      await controller
          .startBuild(
            GenerationRequest(
              jobLabel: 'Native publication acceptance',
              config: const TreeBuildConfig(
                startFen: kStandardStartFen,
                playAsWhite: true,
                maxPly: 1,
                engineThreads: 1,
                useMasterGames: false,
                downloadMasterGamesIfMissing: false,
                verifyFinal: false,
                modelGameCount: 0,
                refutationLines: false,
                alternativeLines: false,
                engineTailPlies: 0,
              ),
              repertoireFilePath: source.path,
              buildRootFen: kStandardStartFen,
              lineMovePrefix: const [],
              repertoireStartFen: kStandardStartFen,
              existingTree: tree,
              existingLineKeys: {
                for (final moves in configuration.existingLineMoves)
                  GenerationRequest.lineKey(moves),
              },
              onPublished: receiver!,
            ),
          )
          .timeout(const Duration(seconds: 60));
      await tester.pump(const Duration(milliseconds: 300));

      expect(controller.isGenerating, isFalse);
      expect(controller.lastError, isNull);
      expect(controller.lastRunSummary, contains('Complete in'));
      final job = JobManager.instance.jobs
          .where((job) => !jobsBefore.contains(job))
          .single;
      expect(job.status, JobStatus.completed);
      expect(job.error, isNull);
      expect(document.currentRepertoire?.filePath, source.path);
      expect(document.isLoading, isFalse);
      expect(document.loadError, isNull);
      expect(document.sourceRevision, isNot(beforeRevision));
      expect(
        document.repertoireLines.map((line) => line.moves),
        unorderedEquals([
          ['d4'],
          ['e4'],
        ]),
      );
      final published = await source.readAsString();
      expect(published, startsWith(originalPgn));
      expect(published, contains('1. e4'));
      expect(document.repertoirePgn, published);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
