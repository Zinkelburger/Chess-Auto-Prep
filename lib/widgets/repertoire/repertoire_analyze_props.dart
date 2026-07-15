/// Shared inputs for analyze-mode panes (lines, coverage, traps, eval, metrics).
library;

import 'package:flutter/material.dart';

import '../../core/repertoire_writer.dart';
import '../../models/build_tree_node.dart';
import '../../models/repertoire_line.dart';
import '../../models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../services/coherence_service.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../../services/generation/fen_map.dart';
import '../../features/eval_tree/widgets/eval_tree_tab.dart';
import 'package:chess_auto_prep/core/navigation_stack.dart';

/// Bundles analyze-mode data and callbacks so zone widgets stay composable.
class RepertoireAnalyzeProps {
  const RepertoireAnalyzeProps({
    required this.lines,
    required this.currentMoveSequence,
    required this.onLineSelected,
    required this.onLineRenamed,
    required this.traps,
    required this.onTrapSelected,
    required this.writer,
    this.coverageResult,
    this.onCoveragePressed,
    this.isCoverageRunning = false,
    this.coverageProgress,
    this.coverageProgressMessage,
    this.onNavigateToPosition,
    this.tree,
    this.fenMap,
    this.isWhiteRepertoire = true,
    this.coherenceResult,
    this.navigationStack,
    this.boardPreview,
    this.currentRepertoire,
    this.treeResetCounter = 0,
    this.onEvalTreePositionSelected,
    this.onStartTrapTour,
  });

  final List<RepertoireLine> lines;
  final List<String> currentMoveSequence;
  final CoverageResult? coverageResult;
  final VoidCallback? onCoveragePressed;
  final bool isCoverageRunning;
  final double? coverageProgress;
  final String? coverageProgressMessage;
  final void Function(RepertoireLine line) onLineSelected;
  final Future<void> Function(RepertoireLine line, String newTitle)
  onLineRenamed;
  final void Function(List<String> moveSequence)? onNavigateToPosition;
  final List<TrapLineInfo> traps;
  final void Function(TrapLineInfo trap) onTrapSelected;
  final BuildTree? tree;
  final FenMap? fenMap;
  final bool isWhiteRepertoire;
  final CoherenceResult? coherenceResult;
  final NavigationStack? navigationStack;
  final BoardPreviewController? boardPreview;
  final RepertoireWriter writer;
  final RepertoireMetadata? currentRepertoire;
  final int treeResetCounter;
  final ValueChanged<EvalTreePositionSelection>? onEvalTreePositionSelected;
  final VoidCallback? onStartTrapTour;

  Map<String, String> get lineNames => {
    for (final line in lines) line.id: line.name,
  };

  bool get hasCoverageView => coverageResult != null;

  bool get hasSuggestionMetrics => coverageResult != null && tree != null;

  bool get hasCoherenceMetrics => coherenceResult != null;

  bool get hasMetricsContent => hasCoherenceMetrics || hasSuggestionMetrics;
}
