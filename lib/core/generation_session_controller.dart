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
import '../services/engine/engine_lifecycle.dart';
import '../services/engine/stockfish_pool.dart';
import '../services/generation/eca_calculator.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../services/generation/line_extractor.dart';
import '../services/generation/pgn_export.dart';
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
import 'generated_repertoire.dart';

/// One exported line from a completed generation run.
class GeneratedLineExport {
  /// Full SAN move list from the repertoire's starting position.
  final List<String> moves;
  final String title;
  final String pgn;

  const GeneratedLineExport({
    required this.moves,
    required this.title,
    required this.pgn,
  });
}

/// Everything a generation run needs, captured at start time so the run is
/// independent of any widget lifecycle.
class GenerationRequest {
  final TreeBuildConfig config;

  /// Repertoire PGN file the generated lines are appended to.
  final String repertoireFilePath;

  /// Position the tree is built from (the current board position).
  final String buildRootFen;

  /// SAN moves from the repertoire's starting position to [buildRootFen].
  /// Exported lines are prefixed with these so they replay from the
  /// repertoire root.
  final List<String> lineMovePrefix;

  /// The repertoire's own starting position (standard FEN when the
  /// repertoire starts from the initial position).  Used for the PGN
  /// `[FEN]` header when [lineMovePrefix] is non-empty.
  final String repertoireStartFen;

  /// Partial tree to resume, or null for a fresh build.
  final BuildTree? existingTree;

  /// Called once with every exported line after the PGN file is written.
  final void Function(List<GeneratedLineExport> lines) onLinesSaved;

  const GenerationRequest({
    required this.config,
    required this.repertoireFilePath,
    required this.buildRootFen,
    required this.lineMovePrefix,
    required this.repertoireStartFen,
    required this.onLinesSaved,
    this.existingTree,
  });
}

class GenerationSessionController extends ChangeNotifier {
  final TreeBuildService buildService = TreeBuildService();
  final CoherenceService coherenceService = CoherenceService();

  static const int _pgnFlushEveryLines = 10;
  static const Duration _notifyThrottle = Duration(milliseconds: 100);
  static const Duration _elapsedTick = Duration(seconds: 1);

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

  bool _snapshotExporting = false;

  /// Live status of an in-flight snapshot export, shown in the Jobs panel.
  /// Null when no snapshot is running.
  String? snapshotStatus;

  bool get isSnapshotExporting => _snapshotExporting;

  RepertoireJob? currentJob;

  /// Config of the most recent run (kept after the run ends so the config
  /// form can restore the user's settings when it remounts).
  TreeBuildConfig? lastConfig;

  /// Human-readable outcome of the most recent run (complete / cancelled /
  /// failed message).  Cleared when a new run starts.
  String lastRunSummary = '';

  /// Non-null when the most recent run failed.
  String? lastError;

  // Progress state (owned by the pipeline, displayed by the Jobs panel).
  String progressStatus = '';
  GenerationPhase progressPhase = GenerationPhase.idle;
  TreeBuildConfig? activeConfig;
  int progressNodes = 0;
  int progressDepth = 0;
  int progressMaxPlyConfig = 20;
  int progressUnexploredAtDepth = 0;
  int progressTotalAtDepth = 0;
  int progressLines = 0;
  double? progressNodesPerMinute;
  double? progressEtaSec;
  int progressElapsedMs = 0;
  bool progressBestFirst = false;
  int progressFrontier = 0;
  double? progressPriorityFraction;
  int? progressRunEtaSec;
  List<int> progressDepthTotals = const [];
  List<int> progressDepthExplored = const [];

  final PgnBatchWriter _pgnWriter = PgnBatchWriter();
  Stopwatch _pipelineSw = Stopwatch();
  Timer? _elapsedTicker;
  Timer? _notifyTimer;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

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
  Future<void> startBuild(GenerationRequest request) async {
    if (_isGenerating) return;

    final config = request.config;
    final filePath = request.repertoireFilePath;
    final existingTree = request.existingTree;

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

    _isGenerating = true;
    _isPaused = false;
    _cancelRequested = false;
    _discardRequested = false;
    _finishNowRequested = false;
    lastError = null;
    lastRunSummary = '';
    lastConfig = config;
    _resetProgress();
    activeConfig = config;
    progressMaxPlyConfig = config.maxPly;
    progressBestFirst = config.bestFirst;
    _pgnWriter.clear();
    _pipelineSw = Stopwatch()..start();
    _startElapsedTicker();

    _repertoireFilePath = filePath;
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

    var engineEntered = false;
    try {
      if (config.needsStockfish) {
        await EngineLifecycle.instance
            .enterGeneration(config.resolvedEngineThreads);
        engineEntered = true;
      }

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
        return;
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
      var selectedCount = selector.select(tree);

      // Phase 2.5: deep verification of the selected repertoire (opt-out).
      // Finish-now skips it: the user asked for lines from what's already
      // built, not another engine pass.
      if (config.verifyFinal &&
          config.needsStockfish &&
          !finishedEarly &&
          !_cancelRequested) {
        _setStatus(
          'Phase 2.5: Verifying repertoire '
          '(depth ${config.resolvedVerifyDepth})...',
          GenerationPhase.verifying,
        );
        try {
          if (StockfishPool.instance.workerCount == 0) {
            await StockfishPool.instance
                .prepareForTreeBuild(config.resolvedEngineThreads);
          }
          final verifier = RepertoireVerifier(config: config);
          final report = await verifier.verify(
            tree,
            fenMap: fenMap,
            ecaCalc: ecaCalc,
            isCancelled: () => _cancelRequested,
            pauseGate: buildService.waitIfPaused,
            onStatus: (s) => _setStatus(s, GenerationPhase.verifying),
          );
          if (report.selectedCount >= 0) {
            selectedCount = report.selectedCount;
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

      if (_cancelRequested) {
        lastRunSummary = 'Cancelled during verification '
            '(${tree.totalNodes} nodes, nothing exported).';
        return;
      }

      // Re-sort children and rebuild metadata now that repertoire flags are
      // set.
      tree.sortAllChildren();
      tree.computeMetadata();

      _setStatus(
        'Phase 3: Extracting lines...',
        GenerationPhase.extractingLines,
      );
      final extractor = LineExtractor(config: config, fenMap: fenMap);
      final extractedLines = extractor.extract(tree);
      if (config.rankLinesByImportance) {
        extractedLines.sort((a, b) => b.probability.compareTo(a.probability));
      }
      updateProgress(lines: extractedLines.length);

      // Publish the bundle (tree + fen map + snapshot + trap index).
      onTreeBuilt(tree);

      final rootFen = prefix.isEmpty ? tree.root.fen : request.repertoireStartFen;
      final rootWhiteToMove = isWhiteToMove(rootFen);
      final saved = <GeneratedLineExport>[];
      for (int i = 0; i < extractedLines.length; i++) {
        final line = extractedLines[i];
        final title = 'Generated Line ${i + 1}';
        final fullMoves = [...prefix, ...line.movesSan];
        final pgn = buildRepertoirePgnEntry(
          moves: fullMoves,
          title: title,
          cumulativeProb: line.probability,
          finalEvalCp: line.leafEvalCp ?? 0,
          isWhiteRepertoire: config.playAsWhite,
          rootFen: rootFen,
          rootWhiteToMove: rootWhiteToMove,
          pruneReason: line.leafPruneReason,
          pruneEvalCp: line.leafPruneEvalCp,
          lineAnnotations: line.moveAnnotations,
          prefixMoveCount: prefix.length,
          rankByImportance: config.rankLinesByImportance,
          annotateMoveProbabilities: config.annotateMoveProbabilities,
          annotateMaiaOnly: config.annotateMaiaOnly,
        );
        _pgnWriter.queue(pgn);
        if (_pgnWriter.lineCount >= _pgnFlushEveryLines) {
          await _pgnWriter.flush(filePath);
        }
        saved.add(
          GeneratedLineExport(moves: fullMoves, title: title, pgn: pgn),
        );
      }
      await _pgnWriter.flush(filePath);
      if (saved.isNotEmpty) {
        request.onLinesSaved(saved);
      }

      String? treeJson;
      try {
        treeJson = serializeTree(tree);
        final base = p.withoutExtension(filePath);
        await StorageFactory.instance.writeFile('${base}_tree.json', treeJson);
      } catch (_) {
        // Tree JSON save is best-effort
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
          'ease_nodes': easeCount,
          'expectimax_nodes': ecaCount,
          'selected_moves': selectedCount,
          'extracted_lines': extractedLines.length,
        },
      );

      // Save trap lines from the bundle's index (always write the file so
      // the UI can distinguish "never generated" from "no traps found").
      try {
        final trapLines = _current?.traps.allTraps ??
            TrapExtractor(playAsWhite: config.playAsWhite).extract(tree);
        await TrapExtractor.saveToFile(trapLines, filePath);
      } catch (_) {
        // Trap extraction is best-effort
      }

      await _deletePartialTree(filePath);

      lastRunSummary = 'Complete: ${tree.totalNodes} nodes, '
          '$selectedCount repertoire moves, '
          '${extractedLines.length} lines. '
          '(ease=$easeCount, expectimax=$ecaCount)';
      if (finishedEarly && config.verifyFinal && config.needsStockfish) {
        lastRunSummary = '$lastRunSummary '
            'Verification skipped (finished early).';
      }
      _setStatus(lastRunSummary, GenerationPhase.extractingLines);
    } on BuildCancelledException catch (e) {
      _cancelRequested = true;
      lastRunSummary = e.message;
    } catch (e) {
      try {
        await _pgnWriter.flush(filePath);
      } catch (_) {
        // Keep the original error; a failed flush must not mask it.
      }
      await _writeFailureDump(config, e);
      lastError = 'Generation failed: $e';
      lastRunSummary = lastError!;
      currentJob?.fail(lastError!);
    } finally {
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
    final seedPly = frontierPly ??
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
      if (failedTree != null) failedTreeJson = serializeTree(failedTree);
    } catch (_) {
      // Partial tree may be unserializable; dump the log regardless.
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
    savePartialTree();
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
      unawaited(EngineLifecycle.instance
          .enterGeneration(cfg.resolvedEngineThreads)
          .whenComplete(buildService.resumeBuild));
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
    if (!_discardRequested) savePartialTree();
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

  // ── Snapshot export (lines-so-far while the run continues) ──────────

  /// Suggested repertoire name for a snapshot export at the current depth.
  String snapshotNameSuggestion() {
    final path = _activeRequest?.repertoireFilePath;
    final base =
        (path == null || path.isEmpty) ? 'Generated' : p.basenameWithoutExtension(path);
    return '$base d$progressDepth snapshot';
  }

  /// Export the lines the build has found so far to a **new** repertoire
  /// file named [repertoireName], without ending the run.
  ///
  /// Unverified exports serialize the tree and run every phase in a
  /// background isolate — the build keeps exploring throughout.  When
  /// [verify] is set (and the config uses Stockfish), exploration pauses
  /// while the engine re-checks the snapshot's chosen moves (the pool is
  /// shared with the build), then resumes automatically.
  ///
  /// Returns (success, user-facing message).
  Future<(bool, String)> exportSnapshot({
    required String repertoireName,
    required bool verify,
  }) async {
    if (!_isGenerating ||
        _cancelRequested ||
        progressPhase != GenerationPhase.buildingTree) {
      return (false, 'No active build to export from.');
    }
    if (_snapshotExporting) {
      return (false, 'A snapshot export is already running.');
    }
    final request = _activeRequest;
    final config = activeConfig;
    final tree = buildService.currentTree;
    if (request == null || config == null || tree == null) {
      return (false, 'Build state unavailable — try again in a moment.');
    }

    final name = repertoireName.trim();
    if (name.isEmpty) return (false, 'Please enter a repertoire name.');
    final storage = StorageFactory.instance;
    final targetPath = await storage.repertoireFilePath(name);
    if (await storage.fileExists(targetPath)) {
      return (false, 'A repertoire named "$name" already exists.');
    }

    final depth = progressDepth;
    final doVerify = verify && config.needsStockfish;
    // Verification shares the engine pool with the build, so exploration
    // pauses for its duration.  Unverified exports never touch the run.
    final pausedForVerify = doVerify && !_isPaused;

    _snapshotExporting = true;
    _setSnapshotStatus('Snapshot: preparing (depth $depth)…');
    try {
      if (pausedForVerify) buildService.pauseBuild();

      // Synchronous, so atomic w.r.t. the async build loop — the copy is a
      // consistent point-in-time snapshot even while BFS continues.
      final exportRequest = SnapshotExportRequest(
        treeJson: serializeTree(tree),
        configJson: Map<String, dynamic>.from(config.toJson()),
        prefix: List<String>.from(_startMoveSequence),
        repertoireStartFen: request.repertoireStartFen,
        stopAfterSelection: doVerify,
      );

      _setSnapshotStatus('Snapshot: computing lines (depth $depth)…');
      final result = await Isolate.run(() => runSnapshotExport(exportRequest));

      var pgnEntries = result.pgnEntries;
      String verifyNote = 'unverified';
      if (doVerify) {
        final snapTree = deserializeTree(result.selectedTreeJson!);
        final fenMap = FenMap()..populate(snapTree.root);
        final ecaCalc = ExpectimaxCalculator(config: config, fenMap: fenMap);
        var verified = false;
        try {
          _setSnapshotStatus(
            'Snapshot: verifying (depth ${config.resolvedVerifyDepth})…',
          );
          if (StockfishPool.instance.workerCount == 0) {
            await StockfishPool.instance
                .prepareForTreeBuild(config.resolvedEngineThreads);
          }
          final verifier = RepertoireVerifier(config: config);
          final report = await verifier.verify(
            snapTree,
            fenMap: fenMap,
            ecaCalc: ecaCalc,
            isCancelled: () => _cancelRequested,
            onStatus: (s) => _setSnapshotStatus('Snapshot: $s'),
          );
          verified = report.completed;
        } catch (e) {
          // Verification is best-effort; export the unverified selection.
          debugPrint('[Snapshot] verification failed: $e');
        }
        // Engine is free again — resume exploration before the extraction
        // walk, which only reads the snapshot copy.
        if (pausedForVerify && !_isPaused) buildService.resumeBuild();
        _setSnapshotStatus('Snapshot: extracting lines…');
        pgnEntries = extractSnapshotLines(
          tree: snapTree,
          config: config,
          fenMap: fenMap,
          prefix: List<String>.from(_startMoveSequence),
          repertoireStartFen: request.repertoireStartFen,
        );
        verifyNote = verified
            ? 'verified at depth ${config.resolvedVerifyDepth}'
            : 'verification incomplete';
      }

      if (pgnEntries.isEmpty) {
        return (
          false,
          'Snapshot produced no lines yet — let the build explore deeper.',
        );
      }

      final header = '// $name Repertoire\n'
          '// Color: ${config.playAsWhite ? 'White' : 'Black'}\n'
          '// Created on ${DateTime.now().toString().split('.')[0]}\n'
          '// Snapshot at depth $depth ($verifyNote) from an in-progress '
          'generation run.\n';
      final buffer = StringBuffer(header);
      for (final pgn in pgnEntries) {
        buffer.writeln();
        buffer.writeln(pgn);
      }
      await storage.writeFile(targetPath, buffer.toString());
      return (
        true,
        'Exported ${pgnEntries.length} lines to "$name" ($verifyNote).',
      );
    } catch (e) {
      debugPrint('[Snapshot] export failed: $e');
      return (false, 'Snapshot export failed: $e');
    } finally {
      if (pausedForVerify && !_isPaused) buildService.resumeBuild();
      _snapshotExporting = false;
      snapshotStatus = null;
      notifyListeners();
    }
  }

  void _setSnapshotStatus(String status) {
    snapshotStatus = status;
    notifyListeners();
  }

  // ── Progress plumbing ────────────────────────────────────────────────

  void _handleBuildProgress(BuildProgress p) {
    // Overwrite even with null: the ETA is per depth layer, and a stale
    // value from the previous layer must not linger into the next one.
    progressEtaSec = p.etaDepthSeconds?.toDouble();
    progressBestFirst = p.bestFirst;
    progressFrontier = p.frontierSize;
    progressPriorityFraction = p.priorityProgress;
    progressRunEtaSec = p.etaRunSeconds;
    progressDepthTotals = p.depthTotals;
    progressDepthExplored = p.depthExplored;
    updateProgress(
      nodes: p.totalNodes,
      depth: p.currentDepth,
      maxPlyConfig: p.maxPlyConfig,
      unexploredAtDepth: p.unexploredAtDepth,
      totalAtDepth: p.totalAtDepth,
      nodesPerMinute: p.nodesPerMinute,
      elapsedMs: _pipelineSw.elapsedMilliseconds,
    );
  }

  void _setStatus(String status, GenerationPhase phase) {
    progressStatus = status;
    progressPhase = phase;
    _flushProgressNotify();
  }

  /// Update observable progress fields.  Listener notification is
  /// throttled: high-frequency build callbacks coalesce to at most one
  /// notify per [_notifyThrottle].
  void updateProgress({
    int? nodes,
    int? depth,
    int? maxPlyConfig,
    int? unexploredAtDepth,
    int? totalAtDepth,
    int? lines,
    double? nodesPerMinute,
    int? elapsedMs,
  }) {
    if (nodes != null) progressNodes = nodes;
    if (depth != null) progressDepth = depth;
    if (maxPlyConfig != null) progressMaxPlyConfig = maxPlyConfig;
    if (unexploredAtDepth != null) {
      progressUnexploredAtDepth = unexploredAtDepth;
    }
    if (totalAtDepth != null) progressTotalAtDepth = totalAtDepth;
    if (lines != null) progressLines = lines;
    if (nodesPerMinute != null) progressNodesPerMinute = nodesPerMinute;
    if (elapsedMs != null) progressElapsedMs = elapsedMs;
    _notifyThrottled();
  }

  void _notifyThrottled() {
    final since = DateTime.now().difference(_lastNotify);
    if (since >= _notifyThrottle) {
      _flushProgressNotify();
    } else {
      _notifyTimer ??= Timer(_notifyThrottle - since, _flushProgressNotify);
    }
  }

  void _flushProgressNotify() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _lastNotify = DateTime.now();
    _syncProgressToJob();
    notifyListeners();
  }

  void _syncProgressToJob() {
    final job = currentJob;
    if (job == null) return;
    final statsLine = buildGenerationStatsLine(
      phase: progressPhase,
      nodes: progressNodes,
      currentDepth: progressDepth,
      maxPlyConfig: progressMaxPlyConfig,
      unexploredAtDepth: progressUnexploredAtDepth,
      totalAtDepth: progressTotalAtDepth,
      nodesPerMinute: progressNodesPerMinute,
      etaDepthSec: progressEtaSec?.round(),
      linesExtracted: progressLines,
      bestFirst: progressBestFirst,
      frontierSize: progressFrontier,
      etaRunSec: progressRunEtaSec,
    );
    job.updateProgress(JobProgress(
      fraction: generationProgressFraction(
            phase: progressPhase,
            currentDepth: progressDepth,
            maxPlyConfig: progressMaxPlyConfig,
            unexploredAtDepth: progressUnexploredAtDepth,
            totalAtDepth: progressTotalAtDepth,
            bestFirst: progressBestFirst,
            priorityProgress: progressPriorityFraction,
          ) ??
          0,
      message: statsLine,
      nodesProcessed: progressNodes,
    ));
  }

  void _startElapsedTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(_elapsedTick, (_) {
      if (!_isGenerating || _isPaused) return;
      updateProgress(elapsedMs: _pipelineSw.elapsedMilliseconds);
    });
  }

  void _stopElapsedTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
  }

  void _resetProgress() {
    progressStatus = '';
    progressPhase = GenerationPhase.idle;
    activeConfig = null;
    progressNodes = 0;
    progressDepth = 0;
    progressMaxPlyConfig = 20;
    progressUnexploredAtDepth = 0;
    progressTotalAtDepth = 0;
    progressLines = 0;
    progressNodesPerMinute = null;
    progressEtaSec = null;
    progressElapsedMs = 0;
    progressBestFirst = false;
    progressFrontier = 0;
    progressPriorityFraction = null;
    progressRunEtaSec = null;
    progressDepthTotals = const [];
    progressDepthExplored = const [];
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
    final playAsWhite = config?.playAsWhite ??
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
