/// Session controller for repertoire tree generation.
///
/// Owns the [TreeBuildService] **and the entire generation pipeline** —
/// Phase 1 build, ease/expectimax/selection, verification, line extraction,
/// and every artifact written to disk.  The config UI
/// ([RepertoireGenerationTab]) only collects a [GenerationRequest] and calls
/// [startBuild]; it can unmount the moment the build starts without
/// affecting the run.  Pause/resume/cancel/finish-now work from any surface
/// (Jobs panel, board overlay) through this controller.
///
/// Collaborators own the parts that are not the running order:
/// [GenerationProgress] (live stats), [SnapshotExporter] (mid-run export),
/// [MasterGamesWait] (parking on a download), [ExpectimaxDatabase] (the
/// published tree bundle and its probes) and [GenerationArtifacts] (the
/// files beside the repertoire).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../features/generation/controllers/generation_publication_controller.dart';
import '../features/generation/models/generation_artifacts.dart';
import '../features/documents/models/pgn_document.dart';
import '../features/generation/models/generation_publication.dart';
import '../chess_core/generation/build_tree_node.dart';
import '../features/settings/controllers/eval_database_settings.dart';
import '../chess_core/generation/trap_line_info.dart';
import '../services/coherence_service.dart';
import '../services/engine/engine_interrupt.dart';
import '../services/engine/engine_lifecycle.dart';
import '../services/engine/stockfish_pool.dart';
import '../services/generation/course/course_builder.dart';
import '../services/generation/eca_calculator.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../services/generation/line_extractor.dart';
import '../services/generation/line_pruner.dart';
import '../services/generation/repertoire_selector.dart';
import '../services/generation/repertoire_verifier.dart';
import '../services/generation/run_debug_dump.dart';
import '../services/generation/trap_extractor.dart';
import '../services/generation/tree_build_progress.dart';
import '../services/generation/tree_ease.dart';
import '../services/generation/tree_my_ease.dart';
import '../services/jobs/generation_phase.dart';
import '../services/jobs/repertoire_job.dart';
import '../services/master_games/master_games_db.dart';
import '../services/master_games/master_games_service.dart';
import '../services/tree_build_service.dart';
import '../utils/chess_utils.dart' show fenAfterMoves;
import '../utils/fen_utils.dart';
import '../utils/findability.dart';
import '../utils/log.dart';
import '../utils/movetext_builder.dart';
import '../utils/safe_change_notifier.dart';
import '../utils/time_format.dart';
import 'expectimax_database.dart';
import 'generated_repertoire.dart';
import '../features/generation/services/generation_artifacts.dart';
import 'generation_progress.dart';
import 'generation_run_summary.dart';
import 'generation_session_types.dart';
import 'master_games_wait.dart';
import 'snapshot_exporter.dart';

class GenerationSessionController extends ChangeNotifier
    with SafeChangeNotifier {
  GenerationSessionController({
    required this._jobs,
    required GenerationPublicationController publication,
    required GenerationArtifacts artifacts,
    required StockfishPool enginePool,
    required EngineLifecycle engineLifecycle,
    required this._databases,
    TreeBuildService? treeBuilder,
  }) : _publication = publication,
       _artifacts = artifacts,
       _enginePool = enginePool,
       _engineLifecycle = engineLifecycle,
       buildService =
           treeBuilder ??
           TreeBuildService(pool: enginePool, lifecycle: engineLifecycle);

  static const String _logName = 'GenerationSession';

  final JobManager _jobs;
  final GenerationPublicationController _publication;
  GenerationSource? _publicationSource;
  GenerationArtifactRun? _artifactRun;
  PgnSnapshot? _publishedSource;
  Future<void> _partialSave = Future.value();
  Future<void> _engineControl = Future.value();

  final StockfishPool _enginePool;
  final EngineLifecycle _engineLifecycle;
  final EvalDatabaseSettings _databases;
  final TreeBuildService buildService;
  final CoherenceService coherenceService = CoherenceService();

  /// The master-games database, consulted when the config asks for it and
  /// it has games.  A supplier because the service loads (and syncs) after
  /// this controller is constructed.
  MasterGamesService Function() masterGames = () => MasterGamesService.instance;

  final GenerationArtifacts _artifacts;
  final MasterGamesWait _masterWait = MasterGamesWait();
  late final ExpectimaxDatabase _database = ExpectimaxDatabase(
    readSaved: _artifacts.readDatabase,
  );

  /// Live BFS / phase stats. The Jobs panel reads this; the pipeline writes it.
  late final GenerationProgress progress = GenerationProgress(
    notify: _publishProgress,
  );

  void _publishProgress() {
    _currentJob?.updateProgress(progress.jobProgress);
    notifyListeners();
  }

  /// Mid-run export of lines found so far, without ending the build.
  late final SnapshotExporter snapshots = SnapshotExporter(
    pool: _enginePool,
    notify: notifyListeners,
    isGenerating: () => _isGenerating,
    isPaused: () => _isPaused,
    cancelRequested: () => _cancelRequested,
    activeRequest: () => _activeRequest,
    activeConfig: () => activeConfig,
    startMoveSequence: () => _startMoveSequence,
    buildService: buildService,
    progress: progress,
  );

  /// Turns the extracted lines into the course document — the enrichment
  /// passes, the model games, the naming and the composition.
  late final CourseBuilder _courseBuilder = CourseBuilder(
    pool: _enginePool,
    isCancelled: () => _cancelRequested,
    onStatus: (message) =>
        progress.setStatus(message, GenerationPhase.extractingLines),
    gameDatabase: () => buildService.lastGameDatabase,
    masterDbFor: _masterDbFor,
    fenMap: () => _database.current?.fenMap,
  );

  bool _isGenerating = false;
  bool _isPaused = false;
  bool _cancelRequested = false;
  bool _finishNowRequested = false;

  /// A discard is a cancel that also throws away the partial tree, so nothing
  /// is left to resume.  Tracked separately from [_cancelRequested] because
  /// the unwind must skip the partial-tree save and delete the file instead.
  bool _discardRequested = false;

  /// Context for saving partial tree state — set at build start so that
  /// pause/cancel from any source can persist the in-progress tree to disk.
  List<String> _startMoveSequence = const [];
  String _startFen = '';

  /// The request of the run in flight, kept so snapshot exports can reuse
  /// the line prefix and repertoire-root FEN.  Null when idle.
  GenerationRequest? _activeRequest;

  RepertoireJob? _currentJob;
  RepertoireJob? get currentJob => _currentJob;

  /// Config of the most recent run (kept after the run ends so the config
  /// form can restore the user's settings when it remounts).
  TreeBuildConfig? lastConfig;

  /// Config of the run in flight. Null when idle. Snapshot export and the
  /// Jobs panel read this; [lastConfig] is the same object after the run ends.
  TreeBuildConfig? activeConfig;

  /// Human-readable outcome of the most recent run (complete / cancelled /
  /// failed message).  Cleared when a new run starts.
  String lastRunSummary = '';

  /// Non-null when the most recent run failed.
  String? lastError;

  bool get isGenerating => _isGenerating;
  bool get isPaused => _isPaused;

  /// True between a cancel request and the pipeline finishing its unwind.
  /// While this holds, a new build cannot start (isGenerating stays true).
  bool get isCancelling => _isGenerating && _cancelRequested;

  /// Whether a pause request would be honored right now. The synchronous
  /// phases (ease/expectimax/selection/extraction) have no pause gate, so
  /// pausing there would free the engine while the pipeline keeps working.
  bool get canPause =>
      !isDisposed &&
      _isGenerating &&
      !_isPaused &&
      !_cancelRequested &&
      progress.phase.isPausable;

  /// True while the run is parked waiting for the master-games download it
  /// asked for.  The lock overlay offers "Start now without them" here.
  bool get isAwaitingMasterGames =>
      _isGenerating && progress.phase == GenerationPhase.downloadingMasterGames;

  bool get isSnapshotExporting => snapshots.isExporting;
  String? get snapshotStatus => snapshots.status;
  String snapshotNameSuggestion() => snapshots.nameSuggestion();
  Future<(bool, String)> exportSnapshot({
    required String repertoireName,
    required bool verify,
  }) => snapshots.export(repertoireName: repertoireName, verify: verify);

  /// The current generated repertoire bundle, or null when none is loaded.
  GeneratedRepertoire? get current => _database.current;

  BuildTree? get generatedTree => current?.tree;
  TreeBuildConfig? get generatedTreeConfig => current?.config;
  FenMap? get generatedTreeFenMap => current?.fenMap;

  /// Read only the board's candidate positions during expansion. Indexing is
  /// incremental at node attachment, never a whole-tree walk on a UI tick.
  BuildTreeNode? liveNodeAt(String fen) =>
      _isGenerating ? buildService.liveNodeAt(fen) : null;

  /// The database to use for this run, or null when off/absent.
  MasterGamesDb? _masterDbFor(TreeBuildConfig config) {
    if (!config.usesMasterGames) return null;
    final service = masterGames();
    if (!service.isAvailableForGeneration) return null;
    return service.db;
  }

  // ── Pipeline ─────────────────────────────────────────────────────────

  /// Run the full generation pipeline.  Never throws: failures land in
  /// [lastError] and fail the job; cancellation lands in [lastRunSummary].
  /// Returns after the run has fully unwound — [isGenerating] is false and
  /// a new build may start.
  ///
  /// This method is the running order and nothing else.  Each phase below
  /// owns its own work and hands the next one a typed result, so a phase can
  /// be read (or changed) without holding the whole pipeline in your head.
  /// Cancellation is checked between phases rather than inside them.
  Future<void> startBuild(GenerationRequest request) async {
    if (_isGenerating || isDisposed) return;

    // Resolve how exported lines relate to the repertoire root before any
    // state changes, so a resume-position mismatch is a clean refusal.
    final List<String> prefix;
    try {
      prefix = request.resolveLinePrefix();
    } on StateError catch (e) {
      lastError = e.message;
      lastRunSummary = e.message;
      notifyListeners();
      return;
    }

    final config = request.config;
    final filePath = request.repertoireFilePath;
    _beginRun(request, prefix);

    var engineEntered = false;
    try {
      if (!request.expectimaxOnly) {
        _publicationSource = await _publication.begin(
          filePath,
          config.toJson(),
        );
        if (_cancelRequested) return;
      }
      _artifactRun = await _artifacts.repository.begin(
        filePath,
        config.toJson(),
        source: _publicationSource,
        expectedGenerationId: request.artifactGeneration,
      );
      await _database.load(
        filePath,
        canApply: () => !isDisposed && !_cancelRequested,
      );
      if (!request.expectimaxOnly) _database.dropTree();
      if (_cancelRequested || isDisposed) return;
      // Before the engine is claimed: an empty master-games database that
      // the config asked to fill is downloaded here, so the build that
      // wanted master practice actually gets it. Holding the engine across
      // a multi-gigabyte download would strand it for nothing.
      await _downloadMasterGamesPhase(config);
      if (_cancelRequested) {
        lastRunSummary = 'Cancelled before the build started.';
        return;
      }

      engineEntered = await _enterEngineIfNeeded(config);
      await _engineControl;
      if (_cancelRequested || isDisposed) {
        lastRunSummary =
            lastError ?? 'Cancelled before the tree build started.';
        return;
      }

      final built = await _buildTreePhase(request, prefix);
      // Null means the run was cancelled mid-build; the summary is already set.
      if (built == null) return;
      final (:tree, :finishedEarly) = built;

      // A probe stops here: fold the tree into the database and report.
      if (request.expectimaxOnly) {
        await _finishExpectimaxProbe(tree, request, prefix);
        return;
      }

      // Selection and verification judge nodes against the same eval window
      // the build applied — the root-anchored one when relativeEval is on.
      final anchored = config.anchoredToRoot(tree.root);
      final analysis = _analyzeTreePhase(tree, anchored);
      await _verifyPhase(
        tree,
        analysis,
        anchored,
        finishedEarly: finishedEarly,
      );
      if (_cancelRequested) {
        lastRunSummary =
            'Cancelled during verification (${tree.totalNodes} nodes, '
            'nothing exported). The explored tree is saved — Finish Now on '
            'the Generate tab builds lines from it.';
        return;
      }

      // Re-sort children and rebuild metadata now that repertoire flags are
      // set.
      tree.sortAllChildren();
      tree.computeMetadata();

      final extracted = _extractLinesPhase(tree, analysis, config);

      // Publish the bundle (tree + fen map + snapshot + trap index).
      onTreeBuilt(tree);

      await _partialSave;
      final proposal = await _artifacts.prepareBundle(
        _artifactRun!,
        tree: tree,
        probes: _database.probes,
        traps: _trapLinesOf(tree, config) ?? const [],
      );
      final exported = await _exportLinesPhase(
        tree,
        extracted,
        request,
        prefix,
      );
      if (exported == null || _cancelRequested || isDisposed) return;
      await _artifacts.repository.select(
        _artifactRun!,
        proposal,
        publishedSource: _publishedSource,
      );
      await _persistArtifactsPhase(tree, analysis, extracted, config, filePath);
      lastRunSummary = composeRunSummary(
        tree: tree,
        analysis: analysis,
        extracted: extracted,
        config: config,
        elapsed: progress.elapsed,
        duplicatesSkipped: exported.duplicatesSkipped,
        courseOutline: exported.built.course.outline,
        enrichment: exported.built.enrichment,
        modelGameNote: exported.modelGameNote,
        bookStats: buildService.buildStats,
        finishedEarly: finishedEarly,
      );
      progress.setStatus(lastRunSummary, GenerationPhase.extractingLines);
    } on BuildCancelledException catch (e) {
      _cancelRequested = true;
      lastRunSummary = e.message;
    } catch (e) {
      if (_cancelRequested && isEngineInterrupt(e)) {
        lastRunSummary = lastRunSummary.isNotEmpty
            ? lastRunSummary
            : 'Build cancelled.';
      } else {
        await _recordFailure(
          config,
          _publishedSource != null && e is GenerationArtifactFailure
              ? StateError(
                  'Generated PGN saved to ${_publishedSource!.path}; $e',
                )
              : e,
        );
      }
    } finally {
      await _endRun(engineEntered: engineEntered, filePath: filePath);
    }
  }

  // ── Master games ─────────────────────────────────────────────────────

  /// Fill an empty master-games database before building, when the config
  /// asked for master practice and
  /// [TreeBuildConfig.downloadMasterGamesIfMissing] is on.  Returns as soon
  /// as the sync ends — finished, cancelled or failed; a failure is not
  /// fatal, the build proceeds without a book.  Does nothing when the
  /// database already has games or when the user declined the wait earlier
  /// this session.
  Future<void> _downloadMasterGamesPhase(TreeBuildConfig config) async {
    if (!config.usesMasterGames || !config.downloadMasterGamesIfMissing) return;
    if (_masterWait.declined || _cancelRequested) return;
    final service = masterGames();
    if (service.hasGames) return;

    progress.setStatus(
      MasterGamesWait.downloadingStatus,
      GenerationPhase.downloadingMasterGames,
    );
    // Mirror the service's own progress line into the build status, so the
    // lock overlay and the job tile show issue counts rather than a bare
    // spinner.
    await _masterWait.park(
      MasterGamesServiceSync(service),
      onStatus: (status) {
        if (!isAwaitingMasterGames) return;
        progress.setStatus(status, GenerationPhase.downloadingMasterGames);
      },
    );
    if (_cancelRequested) return;
    progress.setStatus('Starting build…', GenerationPhase.idle);
  }

  /// "Start now without them": get on with the build using Maia and the
  /// engine alone.  Sticky for the session, so a plan run building one
  /// chapter after another does not ask again for every chapter.
  void skipMasterGamesDownload() {
    if (!isAwaitingMasterGames) return;
    _masterWait.decline();
    progress.setStatus('Starting build…', GenerationPhase.idle);
    notifyListeners();
  }

  // ── Run lifecycle ────────────────────────────────────────────────────

  /// Reset every per-run field and announce the run to listeners/the job tile.
  void _beginRun(GenerationRequest request, List<String> prefix) {
    final config = request.config;
    final existingTree = request.existingTree;

    _publishedSource = null;
    _isGenerating = true;
    _isPaused = false;
    _cancelRequested = false;
    _discardRequested = false;
    _finishNowRequested = false;
    lastError = null;
    lastRunSummary = '';
    lastConfig = config;
    progress.begin();
    activeConfig = config;
    progress.maxPlyConfig = config.maxPly;
    progress.bestFirst = config.bestFirst;

    _startMoveSequence = List.unmodifiable(prefix);
    _startFen = existingTree?.root.fen ?? request.buildRootFen;
    _activeRequest = request;

    coherenceService.invalidate();
    // A full build replaces the tree; a probe adds to the database, and the
    // pane keeps showing it while the probe runs.
    if (!request.expectimaxOnly) _database.dropTree();
    _currentJob = _jobs.createJob(
      type: JobType.generation,
      label: request.jobLabel,
      subtreeFen: _startFen,
      configSnapshot: Map.unmodifiable(config.toJson()),
      status: JobStatus.running,
    );
    _seedResumeProgress(existingTree);
    progress.status = existingTree != null
        ? 'Phase 1: Resuming build...'
        : 'Phase 1: Building tree...';
    progress.phase = GenerationPhase.buildingTree;
    progress.flushNotify();
  }

  /// Unwind the run: release the engine, settle the job tile, clear state.
  /// Runs on every exit path, including failure and cancellation.
  Future<void> _endRun({
    required bool engineEntered,
    required String filePath,
  }) async {
    await _engineControl;
    if (engineEntered) {
      try {
        await _engineLifecycle.exitGeneration();
      } catch (error) {
        final message = 'Engine cleanup failed: $error';
        lastError = message;
        lastRunSummary = message;
        currentJob?.fail(message);
      }
    }
    // A pause/cancel write must finish before discard or a new run can
    // remove/replace its partial tree.
    await _partialSave;
    final source = _publicationSource;
    if (source != null) _publication.finish(source);
    _publicationSource = null;
    // A discarded build leaves nothing to resume: drop the partial tree
    // that cancelBuild would otherwise have saved.
    final artifactRun = _artifactRun;
    if (_discardRequested && artifactRun != null) {
      try {
        final proposal = await _artifacts.repository.prepare(artifactRun, {
          GenerationArtifactKind.partial: null,
        });
        await _artifacts.repository.select(artifactRun, proposal);
      } catch (error) {
        lastError = 'Could not discard saved partial: $error';
        currentJob?.fail(lastError!);
      }
    }
    if (artifactRun != null) _artifacts.repository.close(artifactRun);
    _artifactRun = null;
    if (lastError != null && !isDisposed) {
      try {
        await _database.load(filePath, canApply: () => !isDisposed);
      } catch (_) {
        _database.clear();
      }
    }
    // Release any dangling pause gate so nothing awaits it forever.
    buildService.resumeBuild();
    _finishNowRequested = false;
    final job = currentJob;
    if (job != null) {
      // The completed tile keeps showing progress.message, so replace the
      // last live-stats line with the human outcome sentence.
      if (lastRunSummary.isNotEmpty) {
        job.updateProgress(
          JobProgress(
            fraction: lastError != null || _cancelRequested
                ? job.progress.fraction
                : 1,
            message: lastRunSummary,
            nodesProcessed: job.progress.nodesProcessed,
            totalNodes: job.progress.totalNodes,
          ),
        );
      }
      if (job.status != JobStatus.failed) {
        job.updateStatus(
          _cancelRequested ? JobStatus.cancelled : JobStatus.completed,
        );
      }
      _currentJob = null;
    }
    _isGenerating = false;
    _isPaused = false;
    _cancelRequested = false;
    _discardRequested = false;
    _activeRequest = null;
    activeConfig = null;
    progress.finish();
    progress.flushNotify();
  }

  /// Retain the staged proposal, dump diagnostics, and fail the job tile.
  Future<void> _recordFailure(TreeBuildConfig config, Object error) async {
    await _writeFailureDump(config, error);
    final message = 'Generation failed: $error';
    lastError = message;
    lastRunSummary = message;
    currentJob?.fail(message);
  }

  /// Claim engine threads when the config needs Stockfish.  Returns whether
  /// they were claimed, so [_endRun] knows whether to release them.
  Future<bool> _enterEngineIfNeeded(TreeBuildConfig config) async {
    if (!config.needsStockfish) return false;
    await _engineLifecycle.enterGeneration(config.resolvedEngineThreads);
    return true;
  }

  // ── Phase 1: build the tree ──────────────────────────────────────────

  /// Build (or resume, or skip) the tree.
  ///
  /// Returns null when the run was cancelled during the build — [lastRunSummary]
  /// is set to the cancel/discard wording before returning.  `finishedEarly`
  /// reports whether the user asked to stop and export what exists so far.
  Future<({BuildTree tree, bool finishedEarly})?> _buildTreePhase(
    GenerationRequest request,
    List<String> prefix,
  ) async {
    final config = request.config;
    final existingTree = request.existingTree;

    final BuildTree tree;
    if (config.buildMode == BuildMode.dbExplorer) {
      tree = await buildService.buildFromPgnFreqMap(
        config: config,
        startMoves: prefix.isEmpty ? null : prefix.join(' '),
        isCancelled: () => _cancelRequested,
        finishNow: () => _finishNowRequested,
        onStatusChanged: progress.setStatus,
        onProgress: progress.handleBuildProgress,
      );
    } else if (existingTree != null &&
        existingTree.maxPlyReached >= config.maxPly) {
      tree = existingTree;
      progress.setStatus(
        'Tree already at depth ${existingTree.maxPlyReached}, '
        'skipping build...',
        GenerationPhase.buildingTree,
      );
    } else {
      tree = await buildService.build(
        config: config,
        isCancelled: () => _cancelRequested,
        finishNow: () => _finishNowRequested,
        existingTree: existingTree,
        onProgress: progress.handleBuildProgress,
        masterBook: _masterDbFor(config)?.bookMoves,
      );
    }

    if (_cancelRequested) {
      lastRunSummary = request.expectimaxOnly
          ? 'Expectimax probe cancelled (${tree.totalNodes} nodes, nothing '
                'added).'
          : _discardRequested
          ? 'Build discarded (${tree.totalNodes} nodes).'
          : 'Build cancelled (${tree.totalNodes} nodes) — '
                'resume it anytime from the Generate tab.';
      return null;
    }

    final finishedEarly = _finishNowRequested;
    if (finishedEarly) {
      _finishNowRequested = false;
      progress.setStatus(
        'Finishing early with ${tree.totalNodes} nodes...',
        GenerationPhase.computingEase,
      );
    }

    // Record how this tree relates to the repertoire root so partial
    // saves and future resumes can reconstruct the line prefix.
    if (tree.startMoves.isEmpty && prefix.isNotEmpty) {
      tree.startMoves = prefix.join(' ');
    }

    return (tree: tree, finishedEarly: finishedEarly);
  }

  // ── Phase 2: ease, expectimax, selection ─────────────────────────────

  /// Score the tree and mark the repertoire moves.  Purely synchronous — no
  /// pause gate applies here (see [canPause]).
  TreeAnalysis _analyzeTreePhase(BuildTree tree, TreeBuildConfig config) {
    progress.setStatus(
      'Phase 2: Computing ease...',
      GenerationPhase.computingEase,
    );
    final easeCount = calculateTreeEase(tree);

    progress.setStatus(
      'Phase 2: Computing expectimax...',
      GenerationPhase.computingExpectimax,
    );
    final fenMap = FenMap()..populate(tree.root);
    final ecaCalc = ExpectimaxCalculator(config: config, fenMap: fenMap);
    final ecaCount = ecaCalc.calculate(tree);
    ecaCalc.computeTrapScores(tree.root);
    calculateMyEase(tree, playAsWhite: config.playAsWhite);

    progress.setStatus(
      'Phase 2: Selecting repertoire...',
      GenerationPhase.selectingRepertoire,
    );
    final selector = RepertoireSelector(
      config: config,
      ecaCalc: ecaCalc,
      fenMap: fenMap,
    );

    return TreeAnalysis(
      fenMap: fenMap,
      ecaCalc: ecaCalc,
      easeCount: easeCount,
      ecaCount: ecaCount,
      selectedCount: selector.select(tree),
    );
  }

  // ── Phase 2.5: deep verification (opt-out) ───────────────────────────

  /// Re-check the selected moves at a deeper search depth, revising
  /// [TreeAnalysis.selectedCount] in place when the verifier demotes moves.
  ///
  /// Skipped when the user finished early: they asked for lines from what is
  /// already built, not another engine pass.  Engine failures here are
  /// non-fatal — the build-time evals still stand.
  Future<void> _verifyPhase(
    BuildTree tree,
    TreeAnalysis analysis,
    TreeBuildConfig config, {
    required bool finishedEarly,
  }) async {
    if (!config.runsVerification || finishedEarly || _cancelRequested) {
      return;
    }

    progress.setStatus(
      'Phase 2.5: Verifying repertoire '
      '(depth ${config.resolvedVerifyDepth})...',
      GenerationPhase.verifying,
    );
    try {
      if (_enginePool.workerCount == 0) {
        await _enginePool.prepareForTreeBuild(config.resolvedEngineThreads);
      }
      final verifier = RepertoireVerifier(pool: _enginePool, config: config);
      final report = await verifier.verify(
        tree,
        fenMap: analysis.fenMap,
        ecaCalc: analysis.ecaCalc,
        isCancelled: () => _cancelRequested,
        pauseGate: buildService.waitIfPaused,
        onStatus: (s) => progress.setStatus(s, GenerationPhase.verifying),
      );
      if (report.selectedCount >= 0) {
        analysis.selectedCount = report.selectedCount;
      }
      for (final d in report.demotions) {
        debugPrint('Verification demotion @ ${d.fen}: $d');
      }
      progress.setStatus(report.summary, GenerationPhase.verifying);
    } catch (e) {
      // Verification is best-effort on engine failures; the build-time
      // evals still stand.
      log.w('verification pass failed', name: _logName, error: e);
    }
  }

  // ── Phase 3: extract, filter, and order the lines ────────────────────

  /// Walk the selected tree into concrete lines, then apply the "only traps"
  /// filter, similarity pruning, and importance ranking in that order.
  ExtractedLines _extractLinesPhase(
    BuildTree tree,
    TreeAnalysis analysis,
    TreeBuildConfig config,
  ) {
    progress.setStatus(
      'Phase 3: Extracting lines...',
      GenerationPhase.extractingLines,
    );
    final extractor = LineExtractor(config: config, fenMap: analysis.fenMap);
    var lines = extractor.extract(tree);

    // "Only traps": the tree and the move selection are untouched — we
    // just throw away every line that teaches no trap, so the PGN is a
    // trap collection instead of a repertoire.
    var trapsOnlyNote = '';
    if (config.trapsOnly) {
      final beforeTraps = lines.length;
      final traps = _trapExtractorFor(config).extract(tree);
      lines = keepLinesThroughTraps(lines, traps, (line) => line.movesSan);
      trapsOnlyNote = lines.isEmpty
          ? ' No traps found — nothing exported.'
          : ' Traps only: ${lines.length} of $beforeTraps lines '
                'run through a trap.';
      progress.setStatus(
        'Phase 3: keeping trap lines only '
        '(${lines.length} of $beforeTraps)...',
        GenerationPhase.extractingLines,
      );
    }

    final rawCount = lines.length;
    // Export the whole ranking: every line that teaches a decision no kept
    // line already teaches *and* is different enough from what is already in
    // to be worth its own entry. What gets *kept* is chosen afterwards, on
    // the Generate tab's slice card, against a live count — so this step no
    // longer bakes a size guess into the file.
    final slice = LinePruner.rank(
      lines,
      diversity: LineDiversity.fromConfig(config),
    );
    final folds = slice.foldsFor(slice.length);
    lines = slice.all;
    if (lines.length < rawCount) {
      final folded = slice.foldedCount;
      progress.setStatus(
        'Phase 3: kept ${lines.length} of $rawCount lines'
        '${folded > 0 ? ', $folded folded in as sidelines' : ''} — '
        'the rest only repeated decisions these already teach...',
        GenerationPhase.extractingLines,
      );
    }
    if (config.rankLinesByImportance) {
      lines.sort((a, b) => b.probability.compareTo(a.probability));
    }
    progress.update(lines: lines.length);

    return ExtractedLines(
      lines: lines,
      rawCount: rawCount,
      trapsOnlyNote: trapsOnlyNote,
      folds: folds,
    );
  }

  static TrapExtractor _trapExtractorFor(TreeBuildConfig config) =>
      TrapExtractor(
        playAsWhite: config.playAsWhite,
        findabilityPRef: pRefForElo(config.maiaElo),
      );

  /// The published bundle's trap index, or a fresh extraction when the
  /// bundle is not this [tree]. Null when extraction fails — a failure here
  /// costs the trap list, not the build.
  List<TrapLineInfo>? _trapLinesOf(BuildTree tree, TreeBuildConfig config) {
    try {
      return current?.traps.allTraps ?? _trapExtractorFor(config).extract(tree);
    } catch (e) {
      log.w('trap extraction failed', name: _logName, error: e);
      return null;
    }
  }

  /// Compose the extracted lines into a course — chapters cut at branch
  /// points, named from the ECO book. Stage the complete output before one
  /// revision-checked source commit; never flush an incomplete export.
  Future<({CourseBuild built, int duplicatesSkipped, String modelGameNote})?>
  _exportLinesPhase(
    BuildTree tree,
    ExtractedLines extracted,
    GenerationRequest request,
    List<String> prefix,
  ) async {
    final filePath = request.repertoireFilePath;
    final built = await _courseBuilder.build(
      tree: tree,
      lines: extracted.lines,
      folds: extracted.folds,
      config: request.config,
      repertoireFilePath: filePath,
      rootFen: prefix.isEmpty ? tree.root.fen : request.repertoireStartFen,
      prefix: prefix,
    );
    final course = built.course;
    var modelGameNote = built.modelGameNote;

    final saved = <String>[];
    var duplicatesSkipped = 0;
    for (final entry in course.entries) {
      // Already in the file: writing it again would only duplicate it.
      if (request.existingLineKeys.contains(
        GenerationRequest.lineKey(entry.movesSan),
      )) {
        duplicatesSkipped++;
        continue;
      }
      saved.add(entry.pgn);
    }
    if (_cancelRequested || isDisposed) return null;
    final result = await _publication.publish(
      _publicationSource!,
      games: saved,
      modelGames: course.modelGamePgns.isEmpty ? null : course.modelGamesPgn(),
    );
    switch (result) {
      case GenerationPublished(
        :final staged,
        :final snapshot,
        :final receiptError,
      ):
        _publishedSource = snapshot;
        final path = staged.modelGamesPath;
        if (path != null) {
          modelGameNote = '$modelGameNote Model games saved to $path.';
        }
        if (receiptError != null) {
          modelGameNote =
              '$modelGameNote PGN saved; publication receipt needs '
              'reconciliation at ${staged.manifestPath}.';
        }
        if (!isDisposed) {
          try {
            await request.onPublished(snapshot);
          } catch (error) {
            throw StateError(
              'Generated PGN saved to ${snapshot.path}, but the open chapter '
              'could not refresh: $error',
            );
          }
        }
        if (_cancelRequested) {
          lastRunSummary = 'Generated PGN saved before cancellation.';
        }
      case GenerationPublicationRefused(:final reason, :final staged):
        throw StateError(
          '$reason. Generated output retained at ${staged.manifestPath}.',
        );
      case GenerationPublicationUncertain(:final staged):
        throw StateError(
          'Publication outcome is uncertain; inspect '
          '${staged.manifestPath} before retrying.',
        );
    }
    return (
      built: built,
      duplicatesSkipped: duplicatesSkipped,
      modelGameNote: modelGameNote,
    );
  }

  /// Write the side artifacts: serialized tree, run debug dump, trap index,
  /// and the partial-tree file that makes an unfinished build resumable.
  /// Every step here is best-effort — a completed export must not be undone
  /// by a failure to write diagnostics.
  Future<void> _persistArtifactsPhase(
    BuildTree tree,
    TreeAnalysis analysis,
    ExtractedLines extracted,
    TreeBuildConfig config,
    String filePath,
  ) async {
    // The build is finished here (no concurrent mutator); the indented
    // encode of the whole tree runs off the UI isolate.
    final treeJson = await GenerationArtifacts.encodeTreeSnapshot(tree);

    await writeRunDebugDump(
      log: buildService.runLog,
      config: tree.configSnapshot,
      stats: buildService.buildStats.toJson(),
      prunedTooLow: buildService.lastPrunedTooLow,
      treeJson: treeJson,
      summaryExtras: {
        'total_nodes': tree.totalNodes,
        'max_ply': tree.maxPlyReached,
        'build_complete': tree.buildComplete,
        'build_elapsed_ms': buildService.buildElapsedMs,
        'ease_nodes': analysis.easeCount,
        'expectimax_nodes': analysis.ecaCount,
        'selected_moves': analysis.selectedCount,
        'extracted_lines': extracted.lines.length,
        'raw_extracted_lines': extracted.rawCount,
      },
    );
  }

  /// Seed depth-layer counters so a resumed build doesn't show
  /// "0 / 0 explored" while BFS replays existing nodes toward the frontier.
  void _seedResumeProgress(BuildTree? existingTree) {
    progress.nodes = existingTree?.totalNodes ?? 0;
    if (existingTree == null) return;
    final frontierPly = TreeBuildService.minFrontierPly(existingTree.root);
    final seedPly =
        frontierPly ??
        (existingTree.maxPlyReached > 0 ? existingTree.maxPlyReached : null);
    if (seedPly == null) return;
    final (total, unexplored) = TreeBuildProgressTracker.depthLayerStats(
      existingTree.root,
      seedPly,
    );
    if (frontierPly != null) progress.depth = frontierPly;
    progress.totalAtDepth = total;
    progress.unexploredAtDepth = unexplored;
  }

  Future<void> _writeFailureDump(TreeBuildConfig config, Object error) async {
    final failedTree = buildService.currentTree;
    String? failedTreeJson;
    try {
      // Build has stopped (failure path) — serialize off the UI isolate.
      if (failedTree != null) {
        failedTreeJson = await GenerationArtifacts.encodeTreeSnapshot(
          failedTree,
          indent: false,
        );
      }
    } catch (e) {
      // Partial tree may be unserializable; dump the log regardless.
      log.w('failed-tree serialization failed', name: _logName, error: e);
    }
    await writeRunDebugDump(
      log: buildService.runLog,
      config: failedTree?.configSnapshot ?? config.toJson(),
      stats: buildService.buildStats.toJson(),
      prunedTooLow: buildService.lastPrunedTooLow,
      treeJson: failedTreeJson,
      error: error.toString(),
    );
  }

  Future<({BuildTree tree, String generationId})?> readSavedPartial(
    String path,
  ) => _artifacts.readPartial(path);
  Future<void> discardSavedPartial(String path, String generationId) =>
      _artifacts.discardPartial(path, generationId);

  // ── Partial tree save ────────────────────────────────────────────────

  /// Select an immutable partial generation captured by the active run.
  Future<void> _savePartialTree() async {
    final tree = buildService.currentTree;
    if (tree == null) return;
    final run = _artifactRun;
    if (run == null) return;
    if (tree.startMoves.isEmpty &&
        _startMoveSequence.isNotEmpty &&
        tree.root.fen == _startFen) {
      tree.startMoves = _startMoveSequence.join(' ');
    }
    final pending = _partialSave.then(
      (_) => _artifacts.writePartialTree(tree, run),
    );
    // Partial persistence errors are observed and visible; lifecycle cleanup
    // must still drain and release the job after a failed checkpoint.
    _partialSave = pending.catchError((Object error) {
      lastError = 'Partial tree was not selected: $error';
      currentJob?.fail(lastError!);
    });
    await _partialSave;
  }

  // ── Control methods (callable from anywhere) ────────────────────────

  void pauseBuild() {
    if (!canPause) return;
    buildService.pauseBuild();
    _isPaused = true;
    progress.pause();
    currentJob?.updateStatus(JobStatus.paused);
    // A probe is not resumable from the Generate tab, so it leaves no
    // partial file for that tab to offer.
    if (!isExpectimaxProbe) unawaited(_savePartialTree());
    // Hand the engine back so analysis works everywhere while paused.
    _controlEngine(_engineLifecycle.pauseGeneration);
    progress.flushNotify();
  }

  void resumeBuild() {
    if (isDisposed || !_isPaused) return;
    _isPaused = false;
    progress.resume();
    currentJob?.updateStatus(JobStatus.running);
    progress.flushNotify();
    final cfg = activeConfig;
    if (cfg != null && cfg.needsStockfish) {
      // Re-take the engine (cancels interactive analysis, restores the
      // build's thread config) before releasing the pause gate, so the
      // first build evals don't race user analysis.
      _controlEngine(() async {
        await _engineLifecycle.enterGeneration(cfg.resolvedEngineThreads);
        if (!_cancelRequested && !isDisposed) buildService.resumeBuild();
      });
    } else {
      buildService.resumeBuild();
    }
  }

  /// Drain pause/resume commands before releasing the run's engine ownership.
  /// A control failure is a failed job, never an unobserved async exception.
  void _controlEngine(Future<void> Function() action) {
    _engineControl = _engineControl.then((_) async {
      if (_cancelRequested || isDisposed) return;
      try {
        await action();
      } catch (error) {
        final message = 'Engine control failed: $error';
        lastError = message;
        lastRunSummary = message;
        currentJob?.fail(message);
        cancelBuild();
      }
    });
  }

  /// Request cancellation.  The pipeline unwinds cooperatively;
  /// [isGenerating] stays true (and [isCancelling] reports it) until the
  /// unwind completes, so a new build can never overlap the old one.
  void cancelBuild() {
    if (!_isGenerating || _cancelRequested) return;
    _cancelRequested = true;
    _publication.cancel();
    // A discard throws the tree away, so there is no point saving it here —
    // the unwind deletes the partial file instead.
    if (!_discardRequested && !isExpectimaxProbe) unawaited(_savePartialTree());
    if (_isPaused) {
      _isPaused = false;
      progress.resume();
    }
    buildService.stopBuild();
    // A run parked on the master-games download has no BFS to stop; without
    // this the cancel would not be felt until the whole download finished.
    _masterWait.stopWaiting();
    progress.status = _discardRequested ? 'Discarding…' : 'Cancelling…';
    progress.flushNotify();
  }

  /// Throw the build away entirely: stop the run and delete the partial tree
  /// so nothing lingers to resume.  This is the destructive escape hatch for
  /// a paused build the user has decided they don't want.
  void discardBuild() {
    if (!_isGenerating || _cancelRequested) return;
    _discardRequested = true;
    cancelBuild();
  }

  /// Stop Phase 1 BFS and proceed to selection on the tree built so far.
  /// (Eval enrichment and the coverage sweep still run.)
  ///
  /// Needs no engine: a paused build is unblocked by releasing the pause
  /// gate directly rather than via [resumeBuild], whose Stockfish re-entry
  /// is pointless when the very next loop check exits BFS.  Downstream,
  /// the deep verification pass is skipped for the same reason — the
  /// build-time evals stand as-is.
  void finishNow() {
    if (!_isGenerating || _finishNowRequested || _cancelRequested) return;
    _finishNowRequested = true;
    if (_isPaused) {
      _isPaused = false;
      progress.resume();
      currentJob?.updateStatus(JobStatus.running);
      buildService.resumeBuild();
    }
    notifyListeners();
  }

  // ── Generated tree lifecycle ─────────────────────────────────────────

  /// Publish [tree] as the main tree of the bundle and tell listeners.
  /// See [ExpectimaxDatabase.publish] for how [probes] and [mainIsProbe]
  /// are folded in.
  void onTreeBuilt(
    BuildTree tree, {
    List<BuildTree>? probes,
    bool mainIsProbe = false,
  }) {
    _database.publish(tree, probes: probes, mainIsProbe: mainIsProbe);
    notifyListeners();
  }

  void clearTree() {
    _database.clear();
    coherenceService.invalidate();
    notifyListeners();
  }

  // ── Expectimax database ──────────────────────────────────────────────

  /// Whether the run in flight is an on-demand expectimax probe rather than
  /// a full build.
  bool get isExpectimaxProbe => _activeRequest?.expectimaxOnly ?? false;

  /// Load the expectimax database saved beside [repertoireFilePath]: the
  /// tree the last full build wrote and every probe since. Replaces
  /// whatever is loaded; a repertoire with neither file ends with no tree.
  ///
  /// Idle only — a running build owns the bundle until it finishes.
  Future<void> loadSavedTreeFor(String repertoireFilePath) async {
    if (_isGenerating || isDisposed) return;
    final outcome = await _database.load(
      repertoireFilePath,
      canApply: () => !_isGenerating && !isDisposed,
    );
    switch (outcome) {
      case ExpectimaxLoadOutcome.superseded:
        return;
      case ExpectimaxLoadOutcome.loaded:
        notifyListeners();
      case ExpectimaxLoadOutcome.empty:
        coherenceService.invalidate();
        notifyListeners();
    }
  }

  /// Make sure the loaded database is [target]'s repertoire, loading it
  /// when it is not. Returns why the caller must stop, or null to go on.
  ///
  /// Generate can be opened immediately after selecting a chapter. Waiting
  /// for its saved analysis here means a fast click cannot replace a
  /// database whose background load has not finished yet.
  Future<String?> _ensureDatabaseFor(ExpectimaxProbeTarget target) async {
    await loadSavedTreeFor(target.repertoireFilePath);
    if (isDisposed) return 'Generation was closed.';
    if (_isGenerating) return 'A generation is already running.';
    if (!_database.isFor(target.repertoireFilePath)) {
      return 'The analysis session changed.';
    }
    return null;
  }

  /// The position [target] names, or null when its moves cannot be played
  /// from the repertoire start.
  static String? _probeRootFen(ExpectimaxProbeTarget target) {
    final moves = target.moves;
    final fen = fenAfterMoves(
      target.repertoireStartFen,
      moves,
      moves.length - 1,
    );
    final playedPlies = plyFromFen(fen) - plyFromFen(target.repertoireStartFen);
    return playedPlies == moves.length ? fen : null;
  }

  /// Evaluate a single move and persist its engine continuation, without
  /// exploring an opponent-policy tree or manufacturing an expected score.
  Future<String?> computeMovePv(ExpectimaxProbeTarget target) async {
    if (isDisposed) return 'Generation was closed.';
    if (_isGenerating) return 'A calculation is already running.';
    final moves = target.moves;
    final fen = _probeRootFen(target);
    if (fen == null) {
      return 'The selected move is not legal from this position.';
    }
    final refusal = await _ensureDatabaseFor(target);
    if (refusal != null) return refusal;

    final config = target.movePvConfig(fen);
    final request = GenerationRequest.expectimaxProbe(
      config: config,
      target: target,
      buildRootFen: fen,
      lineMovePrefix: moves,
    );
    _beginRun(request, moves);
    var entered = false;
    try {
      _artifactRun = await _artifacts.repository.begin(
        target.repertoireFilePath,
        config.toJson(),
      );
      await _database.load(
        target.repertoireFilePath,
        canApply: () => !isDisposed && !_cancelRequested,
      );
      if (_cancelRequested || isDisposed) return null;
      entered = await _enterEngineIfNeeded(config);
      if (_cancelRequested) {
        lastRunSummary = 'Move evaluation cancelled.';
        return null;
      }
      progress.setStatus(
        'Evaluating ${target.moveSan ?? 'position'} · engine depth ${config.evalDepth}',
        GenerationPhase.buildingTree,
      );
      final whiteToMove = isWhiteToMove(fen);
      final result = await _enginePool.discoverMoves(
        fen: fen,
        depth: config.evalDepth,
        multiPv: 1,
        isWhiteToMove: whiteToMove,
      );
      if (_cancelRequested) {
        lastRunSummary = 'Move evaluation cancelled.';
        return null;
      }
      if (result.lines.isEmpty) {
        throw StateError('Stockfish returned no continuation');
      }
      final line = result.lines.first;
      final probe = enginePvProbe(
        fen: fen,
        evalCpWhite: line.effectiveCp * (whiteToMove ? 1 : -1),
        pv: line.pv,
        startMoves: moves,
        config: config,
      );
      _database.recordEnginePv(probe);
      notifyListeners();
      await _persistDatabase();
      lastRunSummary =
          '${target.moveSan ?? 'Position'} evaluated · engine depth ${config.evalDepth} · ${probe.root.enginePv.length} PV moves saved';
      return null;
    } catch (error) {
      if (_cancelRequested) {
        lastRunSummary = 'Move evaluation cancelled.';
        return null;
      }
      final message = 'Move evaluation failed: $error';
      lastError = message;
      currentJob?.fail(message);
      return message;
    } finally {
      await _endRun(
        engineEntered: entered,
        filePath: target.repertoireFilePath,
      );
    }
  }

  /// Start an on-demand expectimax probe: a small build rooted at
  /// [target]'s position that is folded into the repertoire's expectimax
  /// database when it finishes. Returns why it could not start, or null
  /// when it did (progress then reports through [progress] and the job).
  ///
  /// The probe borrows the settings of the last build (or the form defaults
  /// when there was none) with everything that is not about scoring the
  /// position switched off — see [ExpectimaxProbeTarget.probeConfig].
  Future<String?> computeExpectimax(ExpectimaxProbeTarget target) async {
    if (isDisposed) return 'Generation was closed.';
    if (_isGenerating) {
      return isExpectimaxProbe
          ? 'An expectimax probe is already running.'
          : 'A build is running — wait for it to finish first.';
    }
    final databases = _databases.state.committed;
    if (databases == null) {
      return 'Load evaluation settings before starting a probe.';
    }
    final moves = target.moves;
    final fen = _probeRootFen(target);
    if (fen == null) {
      return 'Could not play ${moves.join(' ')} from the repertoire start.';
    }
    final refusal = await _ensureDatabaseFor(target);
    if (refusal != null) return refusal;

    final base =
        lastConfig ??
        current?.config ??
        TreeBuildConfig.formDefaults(
          startFen: fen,
          playAsWhite: target.playAsWhite,
        );
    final config = target.probeConfig(
      base: base,
      fen: fen,
      enableChessDbApi: databases.chessDbApiForExpectimax,
    );
    final request = GenerationRequest.expectimaxProbe(
      config: config,
      target: target,
      buildRootFen: fen,
      lineMovePrefix: List.unmodifiable(moves),
    );
    unawaited(startBuild(request));
    return null;
  }

  /// Phase 2 for a probe: land it in the database, republish the bundle and
  /// write it to disk.
  Future<void> _finishExpectimaxProbe(
    BuildTree probe,
    GenerationRequest request,
    List<String> prefix,
  ) async {
    progress.setStatus(
      'Adding to the expectimax database...',
      GenerationPhase.computingExpectimax,
    );
    final config = request.config;
    if (config.boundedDatabase) {
      _database.addBoundedProbe(probe, config: config, prefix: prefix);
      notifyListeners();
      await _persistDatabase();
      lastRunSummary =
          '${probe.totalNodes} positions saved · depth ${probe.maxPlyReached}/${config.maxPly}';
      progress.setStatus(lastRunSummary, GenerationPhase.computingExpectimax);
      return;
    }

    final landing = _database.landProbe(
      probe,
      config: config,
      prefix: prefix,
      repertoireFilePath: request.repertoireFilePath,
    );
    notifyListeners();
    await _persistDatabase();

    final added = landing.added;
    final elapsed = formatCompactDuration(progress.elapsed);
    final where = prefix.isEmpty
        ? 'the start position'
        : buildNumberedMovetext(prefix);
    lastRunSummary =
        'Expectimax computed from $where in $elapsed: $added new '
        'position${added == 1 ? '' : 's'} (${probe.totalNodes} explored).';
    progress.setStatus(lastRunSummary, GenerationPhase.computingExpectimax);
  }

  Future<void> _persistDatabase() async {
    final bundle = _database.current;
    if (bundle == null) return;
    await _artifacts.writeDatabase(
      _artifactRun!,
      probeTrees: [
        if (_database.mainTreeIsProbe) bundle.tree,
        ...bundle.probes,
      ],
      mainTree: _database.mainTreeIsProbe ? null : bundle.tree,
      traps: bundle.traps.allTraps,
    );
  }

  @override
  void dispose() {
    _cancelRequested = true;
    _publication.cancel();
    _masterWait.stopWaiting();
    progress.dispose();
    buildService.stopBuild();
    coherenceService.dispose();
    super.dispose();
  }
}
