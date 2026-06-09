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
  BuildTree? _generatedTree;
  TreeBuildConfig? _generatedTreeConfig;
  FenMap? _generatedTreeFenMap;

  RepertoireJob? currentJob;

  bool get isGenerating => _isGenerating;
  bool get isPaused => _isPaused;
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
    currentJob?.updateStatus(JobStatus.cancelled);
    currentJob = null;
    notifyListeners();
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
    coherenceService.dispose();
    super.dispose();
  }
}
