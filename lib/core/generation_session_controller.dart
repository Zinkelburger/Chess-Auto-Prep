/// Session controller for repertoire tree generation.
///
/// Owns the [TreeBuildService] and observable generation state so that
/// pause/resume/cancel work even after the config dialog is dismissed.
/// The [RepertoireGenerationTab] delegates build lifecycle here while
/// keeping its config UI state locally.
library;

import 'package:flutter/foundation.dart';

import '../models/build_tree_node.dart';
import '../services/coherence_service.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../services/jobs/repertoire_job.dart';
import '../services/tree_build_service.dart';

class GenerationSessionController extends ChangeNotifier {
  final TreeBuildService buildService = TreeBuildService();
  final CoherenceService coherenceService = CoherenceService();

  bool _isGenerating = false;
  bool _isPaused = false;
  bool _finishNowRequested = false;
  BuildTree? _generatedTree;
  TreeBuildConfig? _generatedTreeConfig;
  FenMap? _generatedTreeFenMap;

  RepertoireJob? currentJob;

  // Progress stats (updated by RepertoireGenerationTab)
  String progressStatus = '';
  int progressNodes = 0;
  int progressDepth = 0;
  double? progressNodesPerMinute;
  double? progressEtaSec;
  int progressElapsedMs = 0;

  bool get isGenerating => _isGenerating;
  bool get isPaused => _isPaused;
  bool get finishNowRequested => _finishNowRequested;
  BuildTree? get generatedTree => _generatedTree;
  TreeBuildConfig? get generatedTreeConfig => _generatedTreeConfig;
  FenMap? get generatedTreeFenMap => _generatedTreeFenMap;

  // ── Control methods (callable from anywhere) ────────────────────────

  void pauseBuild() {
    if (!_isGenerating || _isPaused) return;
    buildService.pauseBuild();
    _isPaused = true;
    currentJob?.updateStatus(JobStatus.paused);
    notifyListeners();
  }

  void resumeBuild() {
    if (!_isPaused) return;
    buildService.resumeBuild();
    _isPaused = false;
    currentJob?.updateStatus(JobStatus.running);
    notifyListeners();
  }

  void cancelBuild() {
    if (!_isGenerating) return;
    buildService.stopBuild();
    _isPaused = false;
    _isGenerating = false;
    _finishNowRequested = false;
    currentJob?.updateStatus(JobStatus.cancelled);
    currentJob = null;
    notifyListeners();
  }

  /// Stop Phase 1 BFS and proceed directly to Phase 2 (line selection)
  /// on whatever tree is built so far.
  void finishNow() {
    if (!_isGenerating) return;
    _finishNowRequested = true;
    buildService.stopBuild();
    notifyListeners();
  }

  void clearFinishNow() {
    _finishNowRequested = false;
  }

  // ── State updates (called by RepertoireGenerationTab) ───────────────

  void markGenerating(bool generating) {
    if (_isGenerating == generating) return;
    _isGenerating = generating;
    if (!generating) {
      _isPaused = false;
      if (currentJob != null) {
        currentJob!.updateStatus(JobStatus.completed);
        currentJob = null;
      }
    }
    notifyListeners();
  }

  void onTreeReset() {
    coherenceService.invalidate();
    _generatedTree = null;
    _generatedTreeConfig = null;
    _generatedTreeFenMap = null;
    notifyListeners();
  }

  void onTreeBuilt(BuildTree tree) {
    final fenMap = FenMap()..populate(tree.root);
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
    _generatedTree = tree;
    _generatedTreeFenMap = fenMap;
    _generatedTreeConfig = config;
    notifyListeners();
  }

  void clearTree() {
    _generatedTree = null;
    _generatedTreeConfig = null;
    _generatedTreeFenMap = null;
    coherenceService.invalidate();
    notifyListeners();
  }

  @override
  void dispose() {
    buildService.stopBuild();
    coherenceService.dispose();
    super.dispose();
  }
}
