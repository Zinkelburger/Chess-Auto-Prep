/// Formatting helpers for generation job cards in the Jobs panel.
library;

import 'package:flutter/material.dart';

import '../engine/stockfish_pool.dart';
import '../generation/generation_config.dart';

/// High-level pipeline phase for a generation job.
enum GenerationPhase {
  parsingPgn,
  buildingTree,
  enrichingEvals,
  computingEase,
  computingExpectimax,
  selectingRepertoire,
  extractingLines,
  idle,
}

extension GenerationPhaseLabels on GenerationPhase {
  String get label => switch (this) {
        GenerationPhase.parsingPgn => 'Parsing PGN',
        GenerationPhase.buildingTree => 'Building tree',
        GenerationPhase.enrichingEvals => 'Enriching evals',
        GenerationPhase.computingEase => 'Computing ease',
        GenerationPhase.computingExpectimax => 'Calculating expectimax',
        GenerationPhase.selectingRepertoire => 'Selecting repertoire',
        GenerationPhase.extractingLines => 'Extracting lines',
        GenerationPhase.idle => 'Starting',
      };

  IconData get icon => switch (this) {
        GenerationPhase.parsingPgn => Icons.description_outlined,
        GenerationPhase.buildingTree => Icons.account_tree_outlined,
        GenerationPhase.enrichingEvals => Icons.psychology_outlined,
        GenerationPhase.computingEase => Icons.speed_outlined,
        GenerationPhase.computingExpectimax => Icons.functions_outlined,
        GenerationPhase.selectingRepertoire => Icons.checklist_outlined,
        GenerationPhase.extractingLines => Icons.format_list_numbered_outlined,
        GenerationPhase.idle => Icons.hourglass_empty,
      };
}

/// Infer [GenerationPhase] from the legacy status string set by the tab.
GenerationPhase phaseFromStatus(String status) {
  final lower = status.toLowerCase();
  if (lower.contains('parsing pgn')) return GenerationPhase.parsingPgn;
  if (lower.contains('enriching eval')) return GenerationPhase.enrichingEvals;
  if (lower.contains('computing ease')) return GenerationPhase.computingEase;
  if (lower.contains('computing expectimax')) {
    return GenerationPhase.computingExpectimax;
  }
  if (lower.contains('selecting repertoire')) {
    return GenerationPhase.selectingRepertoire;
  }
  if (lower.contains('extracting lines')) return GenerationPhase.extractingLines;
  if (lower.contains('phase 1') ||
      lower.contains('building tree') ||
      lower.contains('resuming build')) {
    return GenerationPhase.buildingTree;
  }
  return GenerationPhase.idle;
}

String formatJobDuration(Duration d) {
  if (d.inHours > 0) {
    return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
  }
  if (d.inMinutes > 0) {
    return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
  }
  return '${d.inSeconds}s';
}

String formatEtaSeconds(int? sec) {
  if (sec == null || sec <= 0) return '';
  if (sec < 60) return '~${sec}s';
  if (sec < 3600) return '~${(sec / 60).ceil()}m';
  final h = sec ~/ 3600;
  final m = ((sec % 3600) / 60).ceil();
  return '~${h}h ${m}m';
}

/// Live stats line for the active generation phase (C tree_builder style).
String buildGenerationStatsLine({
  required GenerationPhase phase,
  required int nodes,
  required int currentDepth,
  required int maxPlyConfig,
  required int unexploredAtDepth,
  required int totalAtDepth,
  required double? nodesPerMinute,
  required int? etaDepthSec,
  required int linesExtracted,
}) {
  switch (phase) {
    case GenerationPhase.buildingTree:
      final parts = <String>[
        'Depth $currentDepth/$maxPlyConfig',
        '$nodes nodes',
      ];
      if (totalAtDepth > 0) {
        final explored = totalAtDepth - unexploredAtDepth;
        parts.add('$explored/$totalAtDepth explored');
        if (unexploredAtDepth > 0) {
          parts.add('$unexploredAtDepth remaining');
        }
      }
      if (nodesPerMinute != null && nodesPerMinute > 0) {
        parts.add('${nodesPerMinute.toStringAsFixed(0)} n/min');
      }
      final eta = formatEtaSeconds(etaDepthSec);
      if (eta.isNotEmpty) parts.add('ETA $eta');
      return parts.join(' · ');
    case GenerationPhase.enrichingEvals:
      return '$nodes nodes · engine evals in progress';
    case GenerationPhase.parsingPgn:
      return 'Reading game files…';
    case GenerationPhase.extractingLines:
      if (linesExtracted > 0) return '$linesExtracted lines extracted';
      return '$nodes nodes in tree';
    case GenerationPhase.computingEase:
    case GenerationPhase.computingExpectimax:
    case GenerationPhase.selectingRepertoire:
      return '$nodes nodes in tree';
    case GenerationPhase.idle:
      return nodes > 0 ? '$nodes nodes' : 'Preparing…';
  }
}

/// Progress fraction (0–1) for the linear indicator, when meaningful.
double? generationProgressFraction({
  required GenerationPhase phase,
  required int currentDepth,
  required int maxPlyConfig,
  required int unexploredAtDepth,
  required int totalAtDepth,
}) {
  if (phase == GenerationPhase.buildingTree && maxPlyConfig > 0) {
    if (totalAtDepth > 0) {
      final explored = totalAtDepth - unexploredAtDepth;
      final depthBase = (currentDepth / maxPlyConfig).clamp(0.0, 1.0);
      final layerFrac = explored / totalAtDepth;
      return ((depthBase * 0.85) + (layerFrac * 0.15)).clamp(0.0, 1.0);
    }
    return (currentDepth / maxPlyConfig).clamp(0.0, 1.0);
  }
  return null;
}

/// Resource chip text for engine-backed builds.
String? generationResourceLabel(TreeBuildConfig? config) {
  if (config == null || !config.needsStockfish) return null;
  final threads = config.resolvedEngineThreads;
  return '$threads thread${threads == 1 ? '' : 's'} · '
      '$kPoolHashPerWorkerMb MB hash';
}
