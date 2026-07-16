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
import '../utils/safe_change_notifier.dart';
import 'generation_session_types.dart';

export 'generation_session_types.dart'
    show GeneratedLineExport, GenerationRequest;

part 'generation_session_progress.dart';
part 'generation_session_snapshot.dart';

class GenerationSessionController extends ChangeNotifier
    with SafeChangeNotifier, _GenerationProgress, _SnapshotExport {
  final TreeBuildService buildService = TreeBuildService();
  final CoherenceService coherenceService = CoherenceService();

  static const int _pgnFlushEveryLines = 10;

  bool _isGenerating = false;
  bool _isPaused = false;
  bool _cancelRequested = false;
  bool _finishNowRequested = false;

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
        await EngineLifecycle.instance.enterGeneration(
          config.resolvedEngineThreads,
        );
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
        lastRunSummary =
            'Build cancelled (${tree.totalNodes} nodes) — '
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
            await StockfishPool.instance.prepareForTreeBuild(
              config.resolvedEngineThreads,
            );
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
        lastRunSummary =
            'Cancelled during verification '
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

      final rootFen = prefix.isEmpty
          ? tree.root.fen
          : request.repertoireStartFen;
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
        final trapLines =
            _current?.traps.allTraps ??
            TrapExtractor(playAsWhite: config.playAsWhite).extract(tree);
        await TrapExtractor.saveToFile(trapLines, filePath);
      } catch (_) {
        // Trap extraction is best-effort
      }

      await _deletePartialTree(filePath);

      lastRunSummary =
          'Complete: ${tree.totalNodes} nodes, '
          '$selectedCount repertoire moves, '
          '${extractedLines.length} lines. '
          '(ease=$easeCount, expectimax=$ecaCount)';
      if (finishedEarly && config.verifyFinal && config.needsStockfish) {
        lastRunSummary =
            '$lastRunSummary '
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
    savePartialTree();
    if (_isPaused) {
      _isPaused = false;
      _pipelineSw.start();
    }
    buildService.stopBuild();
    progressStatus = 'Cancelling…';
    _flushProgressNotify();
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
