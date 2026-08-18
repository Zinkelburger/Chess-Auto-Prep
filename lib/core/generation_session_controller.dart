/// Session controller for repertoire tree generation.
///
/// Owns the [TreeBuildService] **and the entire generation pipeline** —
/// Phase 1 build, ease/expectimax/selection, verification, line extraction,
/// and every artifact written to disk.  The config UI
/// ([RepertoireGenerationTab]) only collects a [GenerationRequest] and calls
/// [startBuild]; it can unmount the moment the build starts without
/// affecting the run.  Pause/resume/cancel/finish-now work from any surface
/// (Jobs panel, board overlay) through this controller.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/build_tree_node.dart';
import '../services/coherence_service.dart';
import '../utils/log.dart';
import '../services/engine/engine_lifecycle.dart';
import '../services/engine/engine_interrupt.dart';
import '../services/engine/stockfish_pool.dart';
import '../services/generation/course/chapter_titles.dart';
import '../services/generation/course/course_composer.dart';
import '../services/generation/course/model_game_selector.dart';
import '../services/generation/course/opening_namer.dart';
import '../services/generation/course/refutation_prober.dart';
import '../services/generation/eca_calculator.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../services/generation/line_extractor.dart';
import '../services/generation/line_pruner.dart';
import '../services/generation/pgn_export.dart';
import '../services/opening_book_service.dart';
import '../services/generation/repertoire_selector.dart';
import '../services/generation/repertoire_verifier.dart';
import '../services/generation/run_debug_dump.dart';
import '../services/generation/snapshot_export.dart';
import '../services/generation/trap_extractor.dart';
import '../services/generation/tree_build_progress.dart';
import '../services/generation/tree_ease.dart';
import '../services/generation/tree_my_ease.dart';
import '../services/generation/tree_serialization.dart';
import '../services/jobs/generation_job_display.dart';
import '../services/jobs/repertoire_job.dart';
import '../services/storage/storage_factory.dart';
import '../services/tree_build_service.dart';
import '../utils/fen_utils.dart';
import '../utils/findability.dart';
import 'generated_repertoire.dart';
import '../utils/safe_change_notifier.dart';
import 'generation_session_types.dart';

export 'generation_session_types.dart'
    show GeneratedLineExport, GenerationRequest;

part 'generation_session_progress.dart';
part 'generation_session_snapshot.dart';

/// What Phase 2 produces: the scored tree's derived structures plus the
/// counts the run summary and debug dump report.
///
/// Exists so the phase methods hand each other a named result instead of
/// sharing a dozen locals inside one long pipeline method.
class _TreeAnalysis {
  final FenMap fenMap;
  final ExpectimaxCalculator ecaCalc;
  final int easeCount;
  final int ecaCount;

  /// Repertoire moves marked by the selector.  Mutable because Phase 2.5
  /// verification may demote moves and revise the count.
  int selectedCount;

  _TreeAnalysis({
    required this.fenMap,
    required this.ecaCalc,
    required this.easeCount,
    required this.ecaCount,
    required this.selectedCount,
  });
}

/// What Phase 3 produces: the lines to export, plus what was dropped getting
/// there so the summary can explain the shortfall.
class _ExtractedLines {
  /// Lines surviving the trap filter, similarity pruning, and ranking.
  final List<ExtractedLine> lines;

  /// How many lines existed before similarity pruning.
  final int rawCount;

  /// Sentence fragment appended to the run summary when "only traps" ran.
  final String trapsOnlyNote;

  const _ExtractedLines({
    required this.lines,
    required this.rawCount,
    required this.trapsOnlyNote,
  });

  bool get wasPruned => lines.length < rawCount;
}

class GenerationSessionController extends ChangeNotifier
    with SafeChangeNotifier, _GenerationProgress, _SnapshotExport {
  final TreeBuildService buildService = TreeBuildService();
  final CoherenceService coherenceService = CoherenceService();

  static const int _pgnFlushEveryLines = 10;

  bool _isGenerating = false;
  bool _isPaused = false;
  bool _cancelRequested = false;
  bool _finishNowRequested = false;

  /// A discard is a cancel that also throws away the partial tree, so nothing
  /// is left to resume.  Tracked separately from [_cancelRequested] because
  /// the unwind must skip the partial-tree save and delete the file instead.
  bool _discardRequested = false;

  /// Single source of truth for the generated tree and every artifact derived
  /// from it (FenMap, eval-tree snapshot, trap index).
  GeneratedRepertoire? _current;

  /// Context for saving partial tree state — set at build start so that
  /// pause/cancel from any source can persist the in-progress tree to disk.
  String? _repertoireFilePath;
  List<String> _startMoveSequence = const [];
  String _startFen = '';

  /// The request of the run in flight, kept so snapshot exports can reuse
  /// the line prefix and repertoire-root FEN.  Null when idle.
  GenerationRequest? _activeRequest;

  RepertoireJob? currentJob;

  /// Config of the most recent run (kept after the run ends so the config
  /// form can restore the user's settings when it remounts).
  TreeBuildConfig? lastConfig;

  /// Human-readable outcome of the most recent run (complete / cancelled /
  /// failed message).  Cleared when a new run starts.
  String lastRunSummary = '';

  /// Non-null when the most recent run failed.
  String? lastError;

  /// Chapter structure of the most recent export, for the run summary and
  /// for anything that wants to show what the course looks like.
  List<ChapterOutline> lastCourseOutline = const [];

  /// Why the last run produced no model games, or empty when it produced some
  /// (or was not asked for any).
  String lastModelGameNote = '';

  /// Losing replies the last run showed the punishment for.
  int lastRefutationCount = 0;

  /// Positions where the last run showed a refuted move the book leaves out.
  int lastAlternativeCount = 0;

  final PgnBatchWriter _pgnWriter = PgnBatchWriter();
  Stopwatch _pipelineSw = Stopwatch();

  bool get isGenerating => _isGenerating;
  bool get isPaused => _isPaused;

  /// True between a cancel request and the pipeline finishing its unwind.
  /// While this holds, a new build cannot start (isGenerating stays true).
  bool get isCancelling => _isGenerating && _cancelRequested;

  /// Whether a pause request would be honored right now. The synchronous
  /// phases (ease/expectimax/selection/extraction) have no pause gate, so
  /// pausing there would free the engine while the pipeline keeps working.
  bool get canPause =>
      _isGenerating &&
      !_isPaused &&
      !_cancelRequested &&
      progressPhase.isPausable;

  /// The current generated repertoire bundle, or null when none is loaded.
  GeneratedRepertoire? get current => _current;

  // Backward-compatible accessors — all delegate to [_current] so existing
  // call-sites keep working while sharing one source of truth.
  BuildTree? get generatedTree => _current?.tree;
  TreeBuildConfig? get generatedTreeConfig => _current?.config;
  FenMap? get generatedTreeFenMap => _current?.fenMap;

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
    if (_isGenerating) return;

    // Resolve how exported lines relate to the repertoire root before any
    // state changes, so a resume-position mismatch is a clean refusal.
    final List<String> prefix;
    try {
      prefix = _resolveLinePrefix(request);
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
      engineEntered = await _enterEngineIfNeeded(config);

      final built = await _buildTreePhase(request, prefix);
      // Null means the run was cancelled mid-build; the summary is already set.
      if (built == null) return;
      final (:tree, :finishedEarly) = built;

      final analysis = _analyzeTreePhase(tree, config);
      await _verifyPhase(tree, analysis, config, finishedEarly: finishedEarly);
      if (_cancelRequested) {
        lastRunSummary =
            'Cancelled during verification '
            '(${tree.totalNodes} nodes, nothing exported).';
        return;
      }

      // Re-sort children and rebuild metadata now that repertoire flags are
      // set.
      tree.sortAllChildren();
      tree.computeMetadata();

      final extracted = _extractLinesPhase(tree, analysis, config);

      // Publish the bundle (tree + fen map + snapshot + trap index).
      onTreeBuilt(tree);

      await _exportLinesPhase(tree, extracted, request, prefix);
      await _persistArtifactsPhase(tree, analysis, extracted, config, filePath);
      _publishSummary(
        tree,
        analysis,
        extracted,
        config,
        finishedEarly: finishedEarly,
      );
    } on BuildCancelledException catch (e) {
      _cancelRequested = true;
      lastRunSummary = e.message;
    } catch (e) {
      if (_cancelRequested && isEngineInterrupt(e)) {
        lastRunSummary = lastRunSummary.isNotEmpty
            ? lastRunSummary
            : 'Build cancelled.';
      } else {
        await _recordFailure(config, filePath, e);
      }
    } finally {
      await _endRun(engineEntered: engineEntered, filePath: filePath);
    }
  }

  // ── Run lifecycle ────────────────────────────────────────────────────

  /// Reset every per-run field and announce the run to listeners/the job tile.
  void _beginRun(GenerationRequest request, List<String> prefix) {
    final config = request.config;
    final existingTree = request.existingTree;

    _isGenerating = true;
    _isPaused = false;
    _cancelRequested = false;
    _discardRequested = false;
    _finishNowRequested = false;
    lastError = null;
    lastRunSummary = '';
    lastCourseOutline = const [];
    lastModelGameNote = '';
    lastRefutationCount = 0;
    lastAlternativeCount = 0;
    lastConfig = config;
    _resetProgress();
    activeConfig = config;
    progressMaxPlyConfig = config.maxPly;
    progressBestFirst = config.bestFirst;
    _pgnWriter.clear();
    _pipelineSw = Stopwatch()..start();
    _startElapsedTicker();

    _repertoireFilePath = request.repertoireFilePath;
    _startMoveSequence = List.unmodifiable(prefix);
    _startFen = existingTree?.root.fen ?? request.buildRootFen;
    _activeRequest = request;

    coherenceService.invalidate();
    _current = null;
    // Hosts listening for isGenerating create the Jobs-panel job here.
    notifyListeners();
    currentJob
      ?..configSnapshot = Map<String, dynamic>.from(config.toJson())
      ..updateStatus(JobStatus.running);

    _seedResumeProgress(existingTree, config);
    _setStatus(
      existingTree != null
          ? 'Phase 1: Resuming build...'
          : 'Phase 1: Building tree...',
      GenerationPhase.buildingTree,
    );
  }

  /// Unwind the run: release the engine, settle the job tile, clear state.
  /// Runs on every exit path, including failure and cancellation.
  Future<void> _endRun({
    required bool engineEntered,
    required String filePath,
  }) async {
    if (engineEntered) {
      await EngineLifecycle.instance.exitGeneration();
    }
    // A discarded build leaves nothing to resume: drop the partial tree
    // that cancelBuild would otherwise have saved.
    if (_discardRequested) {
      await _deletePartialTree(filePath);
    }
    // Release any dangling pause gate so nothing awaits it forever.
    buildService.resumeBuild();
    _stopElapsedTicker();
    _pipelineSw.stop();
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
      currentJob = null;
    }
    _isGenerating = false;
    _isPaused = false;
    _cancelRequested = false;
    _discardRequested = false;
    _activeRequest = null;
    _resetProgress();
    _flushProgressNotify();
  }

  /// Flush whatever was queued, dump diagnostics, and fail the job tile.
  Future<void> _recordFailure(
    TreeBuildConfig config,
    String filePath,
    Object error,
  ) async {
    try {
      await _pgnWriter.flush(filePath);
    } catch (_) {
      // Keep the original error; a failed flush must not mask it.
    }
    await _writeFailureDump(config, error);
    lastError = 'Generation failed: $error';
    lastRunSummary = lastError!;
    currentJob?.fail(lastError!);
  }

  /// Claim engine threads when the config needs Stockfish.  Returns whether
  /// they were claimed, so [_endRun] knows whether to release them.
  Future<bool> _enterEngineIfNeeded(TreeBuildConfig config) async {
    if (!config.needsStockfish) return false;
    await EngineLifecycle.instance.enterGeneration(
      config.resolvedEngineThreads,
    );
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
        onStatusChanged: _setStatus,
        onProgress: _handleBuildProgress,
      );
    } else {
      final skipBuild =
          existingTree != null && existingTree.maxPlyReached >= config.maxPly;
      if (skipBuild) {
        tree = existingTree;
        _setStatus(
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
          onProgress: _handleBuildProgress,
        );
      }
    }

    if (_cancelRequested) {
      lastRunSummary = _discardRequested
          ? 'Build discarded (${tree.totalNodes} nodes).'
          : 'Build cancelled (${tree.totalNodes} nodes) — '
                'resume it anytime from the Generate tab.';
      return null;
    }

    final finishedEarly = _finishNowRequested;
    if (finishedEarly) {
      _finishNowRequested = false;
      _setStatus(
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
  _TreeAnalysis _analyzeTreePhase(BuildTree tree, TreeBuildConfig config) {
    _setStatus('Phase 2: Computing ease...', GenerationPhase.computingEase);
    final easeCount = calculateTreeEase(tree);

    _setStatus(
      'Phase 2: Computing expectimax...',
      GenerationPhase.computingExpectimax,
    );
    final fenMap = FenMap()..populate(tree.root);
    final ecaCalc = ExpectimaxCalculator(config: config, fenMap: fenMap);
    final ecaCount = ecaCalc.calculate(tree);
    ecaCalc.computeTrapScores(tree.root);
    ecaCalc.calculateCplValues(tree.root);
    calculateMyEase(tree, playAsWhite: config.playAsWhite);

    _setStatus(
      'Phase 2: Selecting repertoire...',
      GenerationPhase.selectingRepertoire,
    );
    final selector = RepertoireSelector(
      config: config,
      ecaCalc: ecaCalc,
      fenMap: fenMap,
    );

    return _TreeAnalysis(
      fenMap: fenMap,
      ecaCalc: ecaCalc,
      easeCount: easeCount,
      ecaCount: ecaCount,
      selectedCount: selector.select(tree),
    );
  }

  // ── Phase 2.5: deep verification (opt-out) ───────────────────────────

  /// Re-check the selected moves at a deeper search depth, revising
  /// [_TreeAnalysis.selectedCount] in place when the verifier demotes moves.
  ///
  /// Skipped when the user finished early: they asked for lines from what is
  /// already built, not another engine pass.  Engine failures here are
  /// non-fatal — the build-time evals still stand.
  Future<void> _verifyPhase(
    BuildTree tree,
    _TreeAnalysis analysis,
    TreeBuildConfig config, {
    required bool finishedEarly,
  }) async {
    if (!config.verifyFinal ||
        !config.needsStockfish ||
        finishedEarly ||
        _cancelRequested) {
      return;
    }

    _setStatus(
      'Phase 2.5: Verifying repertoire '
      '(depth ${config.resolvedVerifyDepth})...',
      GenerationPhase.verifying,
    );
    try {
      if (StockfishPool.instance.workerCount == 0) {
        await StockfishPool.instance.prepareForTreeBuild(
          config.resolvedEngineThreads,
        );
      }
      final verifier = RepertoireVerifier(config: config);
      final report = await verifier.verify(
        tree,
        fenMap: analysis.fenMap,
        ecaCalc: analysis.ecaCalc,
        isCancelled: () => _cancelRequested,
        pauseGate: buildService.waitIfPaused,
        onStatus: (s) => _setStatus(s, GenerationPhase.verifying),
      );
      if (report.selectedCount >= 0) {
        analysis.selectedCount = report.selectedCount;
      }
      for (final d in report.demotions) {
        debugPrint('Verification demotion @ ${d.fen}: $d');
      }
      _setStatus(report.summary, GenerationPhase.verifying);
    } catch (e) {
      // Verification is best-effort on engine failures; the build-time
      // evals still stand.
      debugPrint('Verification pass failed: $e');
    }
  }

  // ── Phase 3: extract, filter, and order the lines ────────────────────

  /// Walk the selected tree into concrete lines, then apply the "only traps"
  /// filter, similarity pruning, and importance ranking in that order.
  _ExtractedLines _extractLinesPhase(
    BuildTree tree,
    _TreeAnalysis analysis,
    TreeBuildConfig config,
  ) {
    _setStatus('Phase 3: Extracting lines...', GenerationPhase.extractingLines);
    final extractor = LineExtractor(config: config, fenMap: analysis.fenMap);
    var lines = extractor.extract(tree);

    // "Only traps": the tree and the move selection are untouched — we
    // just throw away every line that teaches no trap, so the PGN is a
    // trap collection instead of a repertoire.
    var trapsOnlyNote = '';
    if (config.trapsOnly) {
      final beforeTraps = lines.length;
      final traps = TrapExtractor(
        playAsWhite: config.playAsWhite,
        findabilityPRef: pRefForElo(config.maiaElo),
      ).extract(tree);
      lines = keepLinesThroughTraps(lines, traps, (line) => line.movesSan);
      trapsOnlyNote = lines.isEmpty
          ? ' No traps found — nothing exported.'
          : ' Traps only: ${lines.length} of $beforeTraps lines '
                'run through a trap.';
      _setStatus(
        'Phase 3: keeping trap lines only '
        '(${lines.length} of $beforeTraps)...',
        GenerationPhase.extractingLines,
      );
    }

    final rawCount = lines.length;
    if (config.targetLineCount > 0) {
      lines = LinePruner.prune(lines, targetCount: config.targetLineCount);
      if (lines.length < rawCount) {
        _setStatus(
          'Phase 3: kept ${lines.length} of $rawCount lines '
          '(similarity pruning)...',
          GenerationPhase.extractingLines,
        );
      }
    }
    if (config.rankLinesByImportance) {
      lines.sort((a, b) => b.probability.compareTo(a.probability));
    }
    updateProgress(lines: lines.length);

    return _ExtractedLines(
      lines: lines,
      rawCount: rawCount,
      trapsOnlyNote: trapsOnlyNote,
    );
  }

  /// Compose the extracted lines into a course — chapters cut at branch
  /// points, named from the ECO book, with model games appended — and write
  /// it out, flushing in batches so a long export does not sit in memory.
  Future<void> _exportLinesPhase(
    BuildTree tree,
    _ExtractedLines extracted,
    GenerationRequest request,
    List<String> prefix,
  ) async {
    final filePath = request.repertoireFilePath;
    final refutations = await _refutationPhase(extracted, request.config);
    final alternatives = await _alternativePhase(extracted, request.config);
    final course = await _composeCourse(
      tree,
      extracted,
      request,
      prefix,
      refutations,
      alternatives,
    );
    lastCourseOutline = course.outline;

    final saved = <GeneratedLineExport>[];
    for (final entry in course.entries) {
      _pgnWriter.queue(entry.pgn);
      if (_pgnWriter.lineCount >= _pgnFlushEveryLines) {
        await _pgnWriter.flush(filePath);
      }
      saved.add(
        GeneratedLineExport(
          moves: entry.movesSan,
          title: entry.variationName,
          pgn: entry.pgn,
        ),
      );
    }
    await _pgnWriter.flush(filePath);
    if (saved.isNotEmpty) {
      request.onLinesSaved(saved);
    }
  }

  /// Build the course document.  Everything optional here degrades rather
  /// than fails: a missing opening book means move-based chapter names, and
  /// a build with no game database simply has no model games.
  /// Ask the engine how the replies that end a line in a won position are
  /// actually punished, so those lines stop dead on the opponent's mistake.
  ///
  /// Best-effort like verification: no engine, a cancelled run, or a failed
  /// search costs the variations, never the export.
  Future<RefutationMap> _refutationPhase(
    _ExtractedLines extracted,
    TreeBuildConfig config,
  ) async {
    lastRefutationCount = 0;
    if (!config.refutationLines || !config.needsStockfish || _cancelRequested) {
      return const {};
    }

    final prober = RefutationProber(config: config);
    final targets = prober.targets(extracted.lines);
    if (targets.isEmpty) return const {};

    try {
      if (StockfishPool.instance.workerCount == 0) {
        await StockfishPool.instance.prepareForTreeBuild(
          config.resolvedEngineThreads,
        );
      }
      final refutations = await prober.probe(
        extracted.lines,
        isCancelled: () => _cancelRequested,
        onProgress: (done, total) => _setStatus(
          'Phase 3.5: Showing how losing replies are punished '
          '($done of $total)...',
          GenerationPhase.extractingLines,
        ),
      );
      lastRefutationCount = refutations.length;
      return refutations;
    } catch (e) {
      debugPrint('Refutation pass failed: $e');
      return const {};
    }
  }

  /// Ask what a human would play at each position the export passes through
  /// that the book leaves out, and why it is left out.
  ///
  /// Best-effort like [_refutationPhase]: this pass costs variations when it
  /// fails, never the export.
  Future<AlternativeMap> _alternativePhase(
    _ExtractedLines extracted,
    TreeBuildConfig config,
  ) async {
    lastAlternativeCount = 0;
    if (!config.alternativeLines ||
        !config.needsStockfish ||
        _cancelRequested) {
      return const {};
    }

    final prober = RefutationProber(
      config: config,
      freqMap: buildService.lastGameDatabase,
    );
    if (prober.alternativeSites(extracted.lines).isEmpty) return const {};

    try {
      if (StockfishPool.instance.workerCount == 0) {
        await StockfishPool.instance.prepareForTreeBuild(
          config.resolvedEngineThreads,
        );
      }
      final alternatives = await prober.probeAlternatives(
        extracted.lines,
        isCancelled: () => _cancelRequested,
        onProgress: (done, total) => _setStatus(
          'Phase 3.6: Checking the moves the book leaves out '
          '($done of $total positions)...',
          GenerationPhase.extractingLines,
        ),
      );
      lastAlternativeCount = alternatives.length;
      return alternatives;
    } catch (e) {
      debugPrint('Alternatives pass failed: $e');
      return const {};
    }
  }

  Future<ComposedCourse> _composeCourse(
    BuildTree tree,
    _ExtractedLines extracted,
    GenerationRequest request,
    List<String> prefix,
    RefutationMap refutations,
    AlternativeMap alternatives,
  ) async {
    final config = request.config;
    final rootFen = prefix.isEmpty ? tree.root.fen : request.repertoireStartFen;

    final namer = CourseNamer(
      namer: await _loadOpeningNamer(rootFen),
      rootWhiteToMove: isWhiteToMove(rootFen),
      startMoveNumber: fullMoveNumber(rootFen),
      repertoirePrefix: prefix,
      playAsWhite: config.playAsWhite,
    );

    return CourseComposer(
      config: config,
      namer: namer,
      repertoireStartFen: rootFen,
      repertoirePrefix: prefix,
      repertoireName: p.basenameWithoutExtension(request.repertoireFilePath),
    ).compose(
      lines: extracted.lines,
      modelGames: _selectModelGames(tree, config),
      refutations: refutations,
      alternatives: alternatives,
    );
  }

  Future<OpeningNamer> _loadOpeningNamer(String rootFen) async {
    try {
      return OpeningNamer(
        book: await OpeningBookService.instance.load(),
        startFen: rootFen,
      );
    } catch (e) {
      debugPrint('[GenerationController] Opening book unavailable: $e');
      return OpeningNamer.unavailable(startFen: rootFen);
    }
  }

  /// Model games, with [lastModelGameNote] set to why there are none — an
  /// empty trailing section is otherwise indistinguishable from the feature
  /// being off, and "nothing in your database follows this repertoire" is
  /// something the user can act on.
  List<ModelGame> _selectModelGames(BuildTree tree, TreeBuildConfig config) {
    lastModelGameNote = '';
    if (config.modelGameCount <= 0) return const [];

    final database = buildService.lastGameDatabase;
    if (database == null || database.games.isEmpty) {
      lastModelGameNote =
          ' No model games: this build had no game database to draw them from.';
      return const [];
    }

    final games = ModelGameSelector(playAsWhite: config.playAsWhite).select(
      database,
      tree,
      limit: config.modelGameCount,
      fenMap: _current?.fenMap,
    );
    if (games.isEmpty) {
      lastModelGameNote =
          ' No model games: none of the ${database.games.length} strongest '
          'games in the database follow this repertoire.';
    }
    return games;
  }

  /// Write the side artifacts: serialized tree, run debug dump, trap index,
  /// and the partial-tree file that makes an unfinished build resumable.
  /// Every step here is best-effort — a completed export must not be undone
  /// by a failure to write diagnostics.
  Future<void> _persistArtifactsPhase(
    BuildTree tree,
    _TreeAnalysis analysis,
    _ExtractedLines extracted,
    TreeBuildConfig config,
    String filePath,
  ) async {
    String? treeJson;
    try {
      // The build is finished here (no concurrent mutator), so the indented
      // JSON encode of the whole tree can safely run off the UI isolate.
      final json = await Isolate.run(() => serializeTree(tree));
      treeJson = json;
      final base = p.withoutExtension(filePath);
      await StorageFactory.instance.writeFile('${base}_tree.json', json);
    } catch (e) {
      // Tree JSON save is best-effort — log so isolate/send failures aren't silent.
      debugPrint('[GenerationController] Failed to save tree JSON: $e');
    }

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

    // Save trap lines from the bundle's index (always write the file so
    // the UI can distinguish "never generated" from "no traps found").
    try {
      final trapLines =
          _current?.traps.allTraps ??
          TrapExtractor(
            playAsWhite: config.playAsWhite,
            findabilityPRef: pRefForElo(config.maiaElo),
          ).extract(tree);
      await TrapExtractor.saveToFile(trapLines, filePath);
    } catch (e) {
      // Best-effort: a failure here costs the trap list, not the build. Logged
      // because the symptom — a finished repertoire with no traps — is
      // otherwise indistinguishable from a position that genuinely has none.
      log.w(
        'trap extraction failed for $filePath',
        name: 'GenerationSession',
        error: e,
      );
    }

    // A budget/finish-now stop leaves the tree resumable: keep the partial
    // file so the Generate tab offers to continue it.  savePartialTree
    // reads buildService.currentTree, which the skip-build resume path
    // never set — there the on-disk partial already holds this tree.
    if (tree.buildComplete) {
      await _deletePartialTree(filePath);
    } else if (identical(buildService.currentTree, tree)) {
      await savePartialTree();
    }
  }

  /// Compose the one-sentence outcome shown on the job tile and status line.
  void _publishSummary(
    BuildTree tree,
    _TreeAnalysis analysis,
    _ExtractedLines extracted,
    TreeBuildConfig config, {
    required bool finishedEarly,
  }) {
    final pruneNote = extracted.wasPruned
        ? ' (pruned from ${extracted.rawCount})'
        : '';
    final elapsedLabel = formatJobDuration(
      Duration(milliseconds: _pipelineSw.elapsedMilliseconds),
    );
    lastRunSummary =
        'Complete in $elapsedLabel: ${tree.totalNodes} nodes, '
        '${analysis.selectedCount} repertoire moves, '
        '${extracted.lines.length} lines$pruneNote'
        '${_courseNote()}.${extracted.trapsOnlyNote}$lastModelGameNote';
    if (finishedEarly && config.verifyFinal && config.needsStockfish) {
      lastRunSummary =
          '$lastRunSummary '
          'Verification skipped (finished early).';
    }
    _setStatus(lastRunSummary, GenerationPhase.extractingLines);
  }

  /// ` in 7 chapters plus 6 model games`, or empty when the export was flat.
  String _courseNote() {
    if (lastCourseOutline.isEmpty) return '';
    final chapters = lastCourseOutline
        .where((c) => c.kind == ChapterKind.lines)
        .length;
    final games = lastCourseOutline
        .where((c) => c.kind == ChapterKind.modelGames)
        .fold(0, (sum, c) => sum + c.entryCount);
    if (chapters < 2 &&
        games == 0 &&
        lastRefutationCount == 0 &&
        lastAlternativeCount == 0) {
      return '';
    }
    return [
      if (chapters >= 2) ' in $chapters chapters',
      if (games > 0) '${chapters >= 2 ? ' plus' : ' with'} $games model games',
      if (lastRefutationCount > 0) ', $lastRefutationCount punished replies',
      if (lastAlternativeCount > 0)
        ', $lastAlternativeCount refuted alternatives',
    ].join();
  }

  /// SAN prefix (from the repertoire root) that exported lines must carry.
  ///
  /// Fresh builds use the caller's current move sequence.  Resumed builds
  /// trust the prefix recorded on the saved tree — the board may have moved
  /// since the build was paused.  A legacy partial tree without a recorded
  /// prefix can only resume from the exact position it was built from.
  List<String> _resolveLinePrefix(GenerationRequest request) {
    final tree = request.existingTree;
    if (tree == null) return request.lineMovePrefix;
    if (tree.startMoves.isNotEmpty) {
      return tree.startMoves
          .split(' ')
          .where((m) => m.isNotEmpty)
          .toList(growable: false);
    }
    if (tree.root.fen == request.buildRootFen) return request.lineMovePrefix;
    throw StateError(
      'Cannot resume: the paused build started from a different position. '
      'Navigate to that position first, or discard the paused build.',
    );
  }

  /// Seed depth-layer counters so a resumed build doesn't show
  /// "0 / 0 explored" while BFS replays existing nodes toward the frontier.
  void _seedResumeProgress(BuildTree? existingTree, TreeBuildConfig config) {
    progressNodes = existingTree?.totalNodes ?? 0;
    if (existingTree == null) return;
    final frontierPly = TreeBuildService.minFrontierPly(existingTree.root);
    final seedPly =
        frontierPly ??
        (existingTree.maxPlyReached > 0 ? existingTree.maxPlyReached : null);
    if (seedPly == null) return;
    final layer = TreeBuildProgressTracker.depthLayerStats(
      existingTree.root,
      seedPly,
    );
    if (frontierPly != null) progressDepth = frontierPly;
    progressTotalAtDepth = layer.$1;
    progressUnexploredAtDepth = layer.$2;
  }

  Future<void> _writeFailureDump(TreeBuildConfig config, Object error) async {
    final failedTree = buildService.currentTree;
    String? failedTreeJson;
    try {
      // Build has stopped (failure path) — serialize off the UI isolate.
      if (failedTree != null) {
        failedTreeJson = await Isolate.run(() => serializeTree(failedTree));
      }
    } catch (e) {
      // Partial tree may be unserializable; dump the log regardless.
      debugPrint(
        '[GenerationController] Failed to serialize failed-tree JSON: $e',
      );
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

  // ── Partial tree save / delete ───────────────────────────────────────

  /// Persist the in-progress tree to `{repertoire}_partial_tree.json`.
  Future<void> savePartialTree() async {
    final tree = buildService.currentTree;
    if (tree == null) return;
    final filePath = _repertoireFilePath;
    if (filePath == null || filePath.isEmpty) return;
    final base = p.withoutExtension(filePath);
    final path = '${base}_partial_tree.json';
    try {
      if (tree.startMoves.isEmpty &&
          _startMoveSequence.isNotEmpty &&
          tree.root.fen == _startFen) {
        tree.startMoves = _startMoveSequence.join(' ');
      }
      final treeJson = serializeTree(tree);
      await StorageFactory.instance.writeFile(path, treeJson);
    } catch (e) {
      debugPrint('[GenerationController] Failed to save partial tree: $e');
    }
  }

  Future<void> _deletePartialTree(String repertoireFilePath) async {
    final base = p.withoutExtension(repertoireFilePath);
    try {
      await StorageFactory.instance.deleteFile('${base}_partial_tree.json');
    } catch (e) {
      debugPrint('[GenerationController] Failed to delete partial tree: $e');
    }
  }

  // ── Control methods (callable from anywhere) ────────────────────────

  void pauseBuild() {
    if (!canPause) return;
    buildService.pauseBuild();
    _isPaused = true;
    _pipelineSw.stop();
    currentJob?.updateStatus(JobStatus.paused);
    unawaited(savePartialTree());
    // Hand the engine back so analysis works everywhere while paused.
    unawaited(EngineLifecycle.instance.pauseGeneration());
    _flushProgressNotify();
  }

  void resumeBuild() {
    if (!_isPaused) return;
    _isPaused = false;
    _pipelineSw.start();
    currentJob?.updateStatus(JobStatus.running);
    _flushProgressNotify();
    final cfg = activeConfig;
    if (cfg != null && cfg.needsStockfish) {
      // Re-take the engine (cancels interactive analysis, restores the
      // build's thread config) before releasing the pause gate, so the
      // first build evals don't race user analysis.
      unawaited(
        EngineLifecycle.instance
            .enterGeneration(cfg.resolvedEngineThreads)
            .whenComplete(buildService.resumeBuild),
      );
    } else {
      buildService.resumeBuild();
    }
  }

  /// Request cancellation.  The pipeline unwinds cooperatively;
  /// [isGenerating] stays true (and [isCancelling] reports it) until the
  /// unwind completes, so a new build can never overlap the old one.
  void cancelBuild() {
    if (!_isGenerating || _cancelRequested) return;
    _cancelRequested = true;
    // A discard throws the tree away, so there is no point saving it here —
    // the unwind deletes the partial file instead.
    if (!_discardRequested) unawaited(savePartialTree());
    if (_isPaused) {
      _isPaused = false;
      _pipelineSw.start();
    }
    buildService.stopBuild();
    progressStatus = _discardRequested ? 'Discarding…' : 'Cancelling…';
    _flushProgressNotify();
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
      _pipelineSw.start();
      currentJob?.updateStatus(JobStatus.running);
      buildService.resumeBuild();
    }
    notifyListeners();
  }

  // ── Generated tree lifecycle ─────────────────────────────────────────

  void onTreeBuilt(BuildTree tree) {
    TreeBuildConfig? config;
    if (tree.configSnapshot.isNotEmpty) {
      try {
        config = TreeBuildConfig.fromJson(
          tree.configSnapshot,
          startFen: tree.root.fen,
        );
      } catch (e) {
        debugPrint('[GenerationController] Config parse failed: $e');
      }
    }
    final playAsWhite =
        config?.playAsWhite ??
        tree.configSnapshot['play_as_white'] as bool? ??
        tree.root.isWhiteToMove;
    // Derive FenMap, eval-tree snapshot, and trap index once, here.
    _current = GeneratedRepertoire.fromTree(
      tree,
      playAsWhite: playAsWhite,
      config: config,
    );
    notifyListeners();
  }

  void clearTree() {
    _current = null;
    coherenceService.invalidate();
    notifyListeners();
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    _stopElapsedTicker();
    buildService.stopBuild();
    coherenceService.dispose();
    super.dispose();
  }
}
