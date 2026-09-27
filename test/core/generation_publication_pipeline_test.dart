import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/app/engine_runtime.dart';
import '../support/runtime_settings.dart';
import '../support/generation_artifacts_fixture.dart';
import 'dart:io';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/generation_session_controller.dart';
import 'package:chess_auto_prep/core/generation_session_types.dart';
import 'package:chess_auto_prep/features/generation/controllers/generation_publication_controller.dart';
import 'package:chess_auto_prep/infrastructure/generation/storage_generation_draft_repository.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/scripted_document_store.dart';
import 'fake_storage.dart';

class _Lifecycle implements EngineLifecycle {
  void Function()? onEnter;
  @override
  Future<void> enterGeneration(int threads) async => onEnter?.call();
  @override
  Future<void> exitGeneration() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReceiptFailureStorage extends MemoryStorage {
  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (path.endsWith('published.json')) {
      throw StateError('receipt unavailable');
    }
    await super.writeFile(
      path,
      content,
      createOnly: createOnly,
      expectedContent: expectedContent,
    );
  }
}

BuildTree _completedTree() {
  final root = BuildTreeNode(
    fen: kStandardStartFen,
    moveSan: '',
    moveUci: '',
    ply: 0,
    isWhiteToMove: true,
    nodeId: 0,
  )..engineEvalCp = 20;
  root.children.add(
    BuildTreeNode(
      fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
      moveSan: 'e4',
      moveUci: 'e2e4',
      ply: 1,
      isWhiteToMove: false,
      nodeId: 1,
      parent: root,
    )..engineEvalCp = -20,
  );
  return BuildTree(root: root, maxPlyReached: 1)..computeMetadata();
}

RuntimeSettings? _engineFixtureSettings;
EngineRuntime get engines =>
    testEngines(_engineFixtureSettings ??= testRuntimeSettings());
void main() {
  setUp(() {
    _engineFixtureSettings = null;
    addTearDown(() => _engineFixtureSettings?.dispose());
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final outcome in [
    'success',
    'conflict',
    'refresh failure',
    'uncertain',
    'receipt warning',
    'cancel after save',
  ]) {
    final conflict = outcome == 'conflict';
    final refreshFails = outcome == 'refresh failure';
    test('full pipeline: $outcome', () async {
      final directory = await Directory.systemTemp.createTemp(
        'generation-pipeline-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = p.join(directory.path, 'Main.pgn');
      final documents = Store()..current = snapshot('original', path: path);
      final storage = outcome == 'receipt warning'
          ? _ReceiptFailureStorage()
          : MemoryStorage();
      if (outcome == 'uncertain') {
        documents.onSave = (before, content) async => PgnWriteUncertain(
          error: StateError('acknowledgement lost'),
          before: before,
          observed: snapshot(content, path: path, revision: 'uncertain'),
        );
      }
      final lifecycle = _Lifecycle();
      if (conflict) {
        lifecycle.onEnter = () {
          documents.current = snapshot(
            'external edit',
            path: path,
            revision: '2',
          );
        };
      }
      final jobs = JobManager();
      final controller = GenerationSessionController(
        databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
        jobs: jobs,
        enginePool: engines.pool,
        publication: GenerationPublicationController(
          documents: documents,
          drafts: StorageGenerationDraftRepository(
            storage,
            prepareDirectory: (_) async {},
          ),
        ),
        artifacts: generationArtifactsFixture(),
        engineLifecycle: lifecycle,
      );
      addTearDown(controller.dispose);
      final saved = <PgnSnapshot>[];
      await controller.startBuild(
        GenerationRequest(
          jobLabel: 'Test generation',
          config: const TreeBuildConfig(
            startFen: kStandardStartFen,
            playAsWhite: true,
            maxPly: 1,
            useMasterGames: false,
            downloadMasterGamesIfMissing: false,
            verifyFinal: false,
            modelGameCount: 0,
            refutationLines: false,
            alternativeLines: false,
            engineTailPlies: 0,
          ),
          repertoireFilePath: path,
          buildRootFen: kStandardStartFen,
          lineMovePrefix: const [],
          repertoireStartFen: kStandardStartFen,
          existingTree: _completedTree(),
          onPublished: (receipt) async {
            expect(documents.saves, hasLength(1));
            expect(receipt.content, documents.current.content);
            saved.add(receipt);
            await Future<void>.delayed(Duration.zero);
            if (refreshFails) throw StateError('decode unavailable');
            if (outcome == 'cancel after save') controller.cancelBuild();
          },
        ),
      );
      expect(controller.isGenerating, isFalse);
      expect(documents.saves, hasLength(1));
      final job = jobs.jobs.single;
      addTearDown(job.dispose);
      if (conflict) {
        expect(job.status, JobStatus.failed);
        expect(controller.lastError, contains('manifest.json'));
        expect(saved, isEmpty);
        expect(documents.current.content, 'external edit');
        expect(
          storage.files.keys.any((path) => path.endsWith('_tree.json')),
          isFalse,
        );
      } else if (outcome == 'uncertain') {
        expect(job.status, JobStatus.failed);
        expect(
          controller.lastError,
          contains('Publication outcome is uncertain'),
        );
        expect(controller.lastRunSummary, isNot(contains('Complete in')));
        expect(saved, isEmpty);
      } else if (outcome == 'cancel after save') {
        expect(controller.lastError, isNull);
        expect(job.status, JobStatus.cancelled);
        expect(
          controller.lastRunSummary,
          'Generated PGN saved before cancellation.',
        );
        expect(saved, hasLength(1));
        expect(documents.current.content, contains('e4'));
      } else if (refreshFails) {
        expect(job.status, JobStatus.failed);
        expect(controller.lastError, contains('Generated PGN saved'));
        expect(controller.lastError, contains('could not refresh'));
        expect(saved, hasLength(1));
        expect(documents.current.content, contains('e4'));
      } else {
        expect(controller.lastError, isNull);
        expect(job.status, JobStatus.completed);
        expect(saved, isNotEmpty);
        expect(documents.current.content, contains('e4'));
        if (outcome == 'receipt warning') {
          expect(
            controller.lastRunSummary,
            contains('PGN saved; publication receipt needs reconciliation'),
          );
          expect(controller.lastRunSummary, contains('manifest.json'));
        }
      }
    });
  }
}
