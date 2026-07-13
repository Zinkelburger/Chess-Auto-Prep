/// Formatting helpers for generation job cards in the Jobs panel.
library;

import 'package:flutter/material.dart';

import '../engine/stockfish_pool.dart';
import '../generation/generation_config.dart';
import 'generation_phase.dart';

export 'generation_phase.dart';

extension GenerationPhaseLabels on GenerationPhase {
  String get label => switch (this) {
        GenerationPhase.parsingPgn => 'Parsing PGN',
        GenerationPhase.buildingTree => 'Building tree',
        GenerationPhase.enrichingEvals => 'Enriching evals',
        GenerationPhase.computingEase => 'Computing ease',
        GenerationPhase.computingExpectimax => 'Calculating expectimax',
        GenerationPhase.selectingRepertoire => 'Selecting repertoire',
        GenerationPhase.verifying => 'Verifying moves',
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
        GenerationPhase.verifying => Icons.verified_outlined,
        GenerationPhase.extractingLines =>
          Icons.format_list_numbered_outlined,
        GenerationPhase.idle => Icons.hourglass_empty,
      };
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

/// Live stat fragments for the active generation phase (C tree_builder
/// style).
///
/// FIFO (Pure Expectimax) completes depth layers in order, so it shows the
/// current layer's explored count and a per-depth ETA.  Best-first (Fast
/// Expectimax) fills all depths at once, so layer stats would flicker
/// meaninglessly; it shows the deepest ply, the frontier size, and a
/// whole-run ETA derived from the monotone priority descent instead.
List<String> buildGenerationStatParts({
  required GenerationPhase phase,
  required int nodes,
  required int currentDepth,
  required int maxPlyConfig,
  required int unexploredAtDepth,
  required int totalAtDepth,
  required double? nodesPerMinute,
  required int? etaDepthSec,
  required int linesExtracted,
  bool bestFirst = false,
  int frontierSize = 0,
  int? etaRunSec,
}) {
  switch (phase) {
    case GenerationPhase.buildingTree:
      if (bestFirst) {
        final parts = <String>[
          '$nodes nodes',
          'deepest ply $currentDepth/$maxPlyConfig',
        ];
        if (frontierSize > 0) parts.add('frontier $frontierSize');
        if (nodesPerMinute != null && nodesPerMinute > 0) {
          parts.add('${nodesPerMinute.toStringAsFixed(0)} n/min');
        }
        final eta = formatEtaSeconds(etaRunSec);
        if (eta.isNotEmpty) parts.add('ETA $eta');
        return parts;
      }
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
      if (eta.isNotEmpty) parts.add('depth ETA $eta');
      return parts;
    case GenerationPhase.enrichingEvals:
      return ['$nodes nodes', 'engine evals in progress'];
    case GenerationPhase.parsingPgn:
      return ['Reading game files…'];
    case GenerationPhase.verifying:
      return ['$nodes nodes', 'deep-checking selected moves'];
    case GenerationPhase.extractingLines:
      if (linesExtracted > 0) return ['$linesExtracted lines extracted'];
      return ['$nodes nodes in tree'];
    case GenerationPhase.computingEase:
    case GenerationPhase.computingExpectimax:
    case GenerationPhase.selectingRepertoire:
      return ['$nodes nodes in tree'];
    case GenerationPhase.idle:
      return [nodes > 0 ? '$nodes nodes' : 'Preparing…'];
  }
}

/// Joined form of [buildGenerationStatParts] for plain-text consumers.
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
  bool bestFirst = false,
  int frontierSize = 0,
  int? etaRunSec,
}) =>
    buildGenerationStatParts(
      phase: phase,
      nodes: nodes,
      currentDepth: currentDepth,
      maxPlyConfig: maxPlyConfig,
      unexploredAtDepth: unexploredAtDepth,
      totalAtDepth: totalAtDepth,
      nodesPerMinute: nodesPerMinute,
      etaDepthSec: etaDepthSec,
      linesExtracted: linesExtracted,
      bestFirst: bestFirst,
      frontierSize: frontierSize,
      etaRunSec: etaRunSec,
    ).join(' · ');

/// Progress fraction (0–1) for the linear indicator, when meaningful.
///
/// Best-first uses the log-priority descent ([priorityProgress]), which is
/// monotone: children enqueue at a priority ≤ their parent's, so the popped
/// priority only falls, reaching the search floor exactly when the frontier
/// empties.  FIFO approximates by depth layer.
double? generationProgressFraction({
  required GenerationPhase phase,
  required int currentDepth,
  required int maxPlyConfig,
  required int unexploredAtDepth,
  required int totalAtDepth,
  bool bestFirst = false,
  double? priorityProgress,
}) {
  if (phase != GenerationPhase.buildingTree) return null;
  if (bestFirst) return priorityProgress?.clamp(0.0, 1.0);
  if (maxPlyConfig > 0) {
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
