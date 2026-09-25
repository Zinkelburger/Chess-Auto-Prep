import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/app/engine_runtime.dart';
import '../../support/runtime_settings.dart';
import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/generation_session_controller.dart';
import 'package:chess_auto_prep/core/generation_session_types.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/infrastructure/training/training_source_loader.dart';
import 'package:chess_auto_prep/services/asked_questions_store.dart';
import 'package:chess_auto_prep/features/generation/controllers/generation_publication_controller.dart';
import 'package:chess_auto_prep/features/generation/models/generation_artifacts.dart';
import 'package:chess_auto_prep/features/generation/services/generation_artifacts.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/generation/storage_generation_artifact_repository.dart';
import 'package:chess_auto_prep/infrastructure/generation/storage_generation_draft_repository.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/tree_build_service.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../services/generation/engine_fakes.dart';
import '../../services/training/training_fakes.dart';

class _FailSelection extends StorageGenerationArtifactRepository {
  _FailSelection({required super.storage, required super.documents});
  String? proposalPath;
  @override
  Future<void> select(
    GenerationArtifactRun run,
    GenerationArtifactProposal proposal, {
    PgnSnapshot? publishedSource,
  }) async {
    proposalPath = proposal.manifestPath;
    throw GenerationArtifactFailure(
      'Injected selection failure',
      proposalPath: proposal.manifestPath,
    );
  }
}

class _Lifecycle implements EngineLifecycle {
  @override
  Future<void> enterGeneration(int threads) async {}
  @override
  Future<void> exitGeneration() async {}
  @override
  Future<void> pauseGeneration() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BuildTree _tree({bool complete = true}) {
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
      fen: playUciMove(kStandardStartFen, 'e2e4')!,
      moveSan: 'e4',
      moveUci: 'e2e4',
      ply: 1,
      isWhiteToMove: false,
      nodeId: 1,
      parent: root,
    )..engineEvalCp = -20,
  );
  return BuildTree(
    root: root,
    totalNodes: 2,
    maxPlyReached: 1,
    buildComplete: complete,
  )..computeMetadata();
}

class _GatedBuild extends TreeBuildService {
  _GatedBuild() : super(pool: engines.pool, lifecycle: engines.lifecycle);
  final tree = _tree(complete: false);
  final entered = Completer<void>();
  final finish = Completer<void>();
  @override
  BuildTree? get currentTree => tree;
  @override
  Future<BuildTree> build({
    required TreeBuildConfig config,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
    bool Function()? finishNow,
    BuildTree? existingTree,
    BookLookup? masterBook,
  }) async {
    tree.configSnapshot = config.toJson();
    entered.complete();
    await finish.future;
    await waitIfPaused();
    return tree;
  }

  @override
  void stopBuild() {
    resumeBuild();
    if (!finish.isCompleted) finish.complete();
  }
}

const _config = TreeBuildConfig(
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
);

RuntimeSettings? _engineFixtureSettings;
EngineRuntime get engines =>
    testEngines(_engineFixtureSettings ??= testRuntimeSettings());
void main() {
  setUp(() {
    _engineFixtureSettings = null;
    addTearDown(() => _engineFixtureSettings?.dispose());
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String path;
  late IOStorageService storage;
  late NativePgnDocumentStore documents;
  late StorageGenerationArtifactRepository repository;
  late GenerationArtifacts artifacts;
  final controllers = <GenerationSessionController>[];
  GenerationSessionController controller({
    FakeStockfishPool? pool,
    TreeBuildService? build,
  }) {
    final value = GenerationSessionController(
      databases: (_engineFixtureSettings ??= testRuntimeSettings()).databases,
      jobs: JobManager(),
      publication: GenerationPublicationController(
        documents: documents,
        drafts: StorageGenerationDraftRepository(storage),
      ),
      artifacts: artifacts,
      engineLifecycle: _Lifecycle(),
      enginePool: pool ?? engines.pool,
      treeBuilder: build,
    );
    controllers.add(value);
    return value;
  }

  GenerationRequest request({
    BuildTree? tree,
    String? generation,
    TreeBuildConfig config = _config,
  }) => GenerationRequest(
    jobLabel: 'Test generation',
    config: config,
    repertoireFilePath: path,
    buildRootFen: kStandardStartFen,
    lineMovePrefix: [],
    repertoireStartFen: kStandardStartFen,
    existingTree: tree,
    artifactGeneration: generation,
    onPublished: (_) {},
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'native-artifact-pipeline-',
    );
    path = p.join(directory.path, 'Main.pgn');
    storage = IOStorageService(
      documentsRoot: directory,
      supportRoot: directory,
    );
    documents = NativePgnDocumentStore();
    await documents.create(path, '[Event "Original"]\n\n1. d4 d5 *\n');
    repository = StorageGenerationArtifactRepository(
      storage: storage,
      documents: documents,
    );
    artifacts = GenerationArtifacts(repository);
  });
  tearDown(() async {
    for (final value in controllers) {
      value.dispose();
    }
    controllers.clear();
    await directory.delete(recursive: true);
  });

  test(
    'native generate → reopen → PV update → reopen uses one coherent authority',
    () async {
      final first = controller();
      await first.startBuild(request(tree: _tree()));
      expect(first.lastError, isNull);
      final selected = await repository.read(path);
      expect(selected.origin, GenerationArtifactOrigin.current);
      expect(
        selected.payloads.keys,
        containsAll([
          GenerationArtifactKind.tree,
          GenerationArtifactKind.probes,
          GenerationArtifactKind.traps,
        ]),
      );
      expect(
        selected.payloads.containsKey(GenerationArtifactKind.partial),
        isFalse,
      );
      expect(
        await File('${p.withoutExtension(path)}_tree.json').exists(),
        isFalse,
      );
      final loader = TrainingSourceLoader(
        documents: documents,
        repertoireService: FakeRepertoireService(),
        reviewService: FakeReviewService(),
        askedQuestions: AskedQuestionsStore(),
        artifacts: repository,
      );
      final lines = [
        fakeLine('generated', ['e4']),
      ];
      expect(
        (await loader.playabilityFromTree(path, lines)).keys,
        contains('generated'),
      );
      final fen = playUciMove(kStandardStartFen, 'd2d4')!;
      final pool = FakeStockfishPool();
      pool.discoveryByFen[fen] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: 30, pv: ['d7d5']),
        ],
        depth: 14,
      );
      final reopened = controller(pool: pool);
      await reopened.loadSavedTreeFor(path);
      expect(reopened.generatedTree!.root.fen, kStandardStartFen);
      expect(
        await reopened.computeMovePv(
          ExpectimaxProbeTarget(
            repertoireFilePath: path,
            repertoireStartFen: kStandardStartFen,
            movesFromStart: [],
            moveSan: 'd4',
            plies: 1,
            playAsWhite: true,
          ),
        ),
        isNull,
      );
      final again = controller();
      await again.loadSavedTreeFor(path);
      expect(again.generatedTreeFenMap!.getCanonical(fen)!.enginePv, ['d7d5']);
      expect(await artifacts.readTraps(path), isNotNull);
      expect(
        (await repository.read(path)).generationId,
        isNot(selected.generationId),
      );
      // Existing legacy files cannot override a source-invalidated generation.
      await File(
        '${p.withoutExtension(path)}_tree.json',
      ).writeAsString(selected.payloads[GenerationArtifactKind.tree]!);
      await File(path).writeAsString('[Event "External"]\n\n1. c4 *\n');
      expect(await loader.playabilityFromTree(path, lines), isEmpty);
      expect(await artifacts.readTraps(path), isNull);
      await again.loadSavedTreeFor(path);
      expect(again.generatedTree, isNull);
    },
  );

  test(
    'source saved but artifact selection failed reports retained proposal',
    () async {
      final failing = _FailSelection(storage: storage, documents: documents);
      artifacts = GenerationArtifacts(failing);
      final first = controller();
      await first.startBuild(request(tree: _tree()));
      expect(await File(path).readAsString(), contains('e4'));
      expect(first.lastError, contains('Generated PGN saved'));
      expect(first.lastError, contains(failing.proposalPath!));
      expect(await File(failing.proposalPath!).exists(), isTrue);
      expect(
        (await repository.read(path)).origin,
        GenerationArtifactOrigin.absent,
      );
      expect(first.generatedTree, isNull);
      expect(first.isGenerating, isFalse);
    },
  );

  test(
    'pause, live resume, cancel and reopened resume keep the source-bound partial',
    () async {
      final build = _GatedBuild();
      final first = controller(build: build);
      final running = first.startBuild(
        request(config: _config.copyWith(maxPly: 2)),
      );
      addTearDown(() async {
        first.cancelBuild();
        await running;
      });
      await build.entered.future;
      first.pauseBuild();
      expect(first.isPaused, isTrue);
      ({BuildTree tree, String generationId})? partial;
      for (var n = 0; n < 100 && partial == null; n++) {
        partial = await first.readSavedPartial(path);
        if (partial == null) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      expect(partial, isNotNull);
      expect(partial!.tree.totalNodes, 2);
      first.resumeBuild();
      expect(first.isPaused, isFalse);
      first.cancelBuild();
      await running;
      expect(first.lastError, isNull);
      final reopened = controller();
      final saved = (await reopened.readSavedPartial(path))!;
      await reopened.startBuild(
        request(tree: saved.tree, generation: saved.generationId),
      );
      expect(reopened.lastError, isNull);
      expect(
        (await repository.read(path)).origin,
        GenerationArtifactOrigin.current,
      );
      expect(await File(path).readAsString(), contains('e4'));
      expect(
        (await reopened.readSavedPartial(path))!.generationId,
        isNot(saved.generationId),
      );
    },
  );
}
