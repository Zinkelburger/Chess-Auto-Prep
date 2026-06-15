/// Builds analyze-mode zone widgets from [RepertoireAnalyzeProps].
library;

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/features/coverage/services/coverage_suggestion_service.dart';
import 'package:chess_auto_prep/features/coverage/widgets/suggestion_panel.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/features/traps/widgets/traps_browser.dart';
import '../../core/board_preview_controller.dart';
import '../../features/eval_tree/widgets/eval_tree_tab.dart';
import '../../features/coverage/services/coverage_service.dart';
import '../../theme/app_colors.dart';
import '../coherence_panel.dart';
import '../layout/analyze_context_zone.dart';
import '../layout/analyze_main_zone.dart';
import 'repertoire_analyze_props.dart';
import 'repertoire_lines_with_traps.dart';

export 'repertoire_analyze_props.dart';

/// Factory helpers for wide (split zones) and compact (stacked) analyze layouts.
class RepertoireAnalyzePane {
  const RepertoireAnalyzePane._();

  /// Compact/mobile layout: collapsible sections in one column.
  static Widget buildCompact(RepertoireAnalyzeProps props) {
    return RepertoireLinesWithTraps(props: props);
  }

  /// Wide layout main column: lines browser + optional coverage tab.
  static Widget buildMainZone(RepertoireAnalyzeProps props) {
    return AnalyzeMainZone.withLinesBrowser(
      lines: props.lines,
      currentMoveSequence: props.currentMoveSequence,
      onLineSelected: props.onLineSelected,
      onLineRenamed: props.onLineRenamed,
      onCoveragePressed: props.onCoveragePressed,
      isCoverageRunning: props.isCoverageRunning,
      coverageResult: props.coverageResult,
      onNavigateToPosition: props.onNavigateToPosition,
      coverageProgress: props.coverageProgress,
      coverageProgressMessage: props.coverageProgressMessage,
      tree: props.tree,
      fenMap: props.fenMap,
      isWhiteRepertoire: props.isWhiteRepertoire,
      traps: props.traps,
      coherenceResult: props.coherenceResult,
      navigationStack: props.navigationStack,
      coverageContent: props.hasCoverageView
          ? _CoverageDetailView(
              result: props.coverageResult!,
              onNavigateToPosition: props.onNavigateToPosition,
            )
          : null,
    );
  }

  /// Wide layout context column: traps, eval tree, and line metrics chips.
  static Widget buildContextZone(RepertoireAnalyzeProps props) {
    return AnalyzeContextZone(
      trapsContent: props.traps.isNotEmpty
          ? TrapsBrowser(
              traps: props.traps,
              currentMoveSequence: props.currentMoveSequence,
              boardPreview: props.boardPreview,
              onTrapSelected: props.onTrapSelected,
              metrics: TrapIndexService(props.traps).metrics,
              onStartTour: props.onStartTrapTour,
            )
          : null,
      evalTreeContent: props.currentRepertoire != null
          ? EvalTreeTab(
              currentRepertoire: props.currentRepertoire,
              isWhiteRepertoire: props.isWhiteRepertoire,
              generatedTree: props.tree,
              treeResetCounter: props.treeResetCounter,
              onPositionSelected: props.onEvalTreePositionSelected,
            )
          : null,
      metricsContent:
          props.hasMetricsContent ? _AnalyzeMetricsView(props: props) : null,
    );
  }
}

class _AnalyzeMetricsView extends StatelessWidget {
  const _AnalyzeMetricsView({required this.props});

  final RepertoireAnalyzeProps props;

  Future<void> _acceptSuggestion(
    BuildContext context,
    SuggestedLine suggestion,
  ) async {
    try {
      await props.writer.acceptSuggestion(suggestion);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Added ${suggestion.newMoves.join(' ')} to repertoire',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('[RepertoireAnalyzePane] Failed to accept suggestion: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add suggestion: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasCoherence = props.hasCoherenceMetrics;
    final hasSuggestions = props.hasSuggestionMetrics;

    if (hasCoherence && hasSuggestions) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: CoherencePanel(
              result: props.coherenceResult!,
              lineNames: props.lineNames,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SuggestionPanel(
              service: CoverageSuggestionService(
                coverage: props.coverageResult!,
                tree: props.tree,
                fenMap: props.fenMap,
                coherence: props.coherenceResult,
              ),
              playAsWhite: props.isWhiteRepertoire,
              boardPreview: props.boardPreview ?? BoardPreviewController(),
              currentCoverage: props.coverageResult!.coveragePercent,
              onAccept: (suggestion) => _acceptSuggestion(context, suggestion),
            ),
          ),
        ],
      );
    }

    if (hasCoherence) {
      return CoherencePanel(
        result: props.coherenceResult!,
        lineNames: props.lineNames,
      );
    }

    return SuggestionPanel(
      service: CoverageSuggestionService(
        coverage: props.coverageResult!,
        tree: props.tree,
        fenMap: props.fenMap,
        coherence: props.coherenceResult,
      ),
      playAsWhite: props.isWhiteRepertoire,
      boardPreview: props.boardPreview ?? BoardPreviewController(),
      currentCoverage: props.coverageResult!.coveragePercent,
      onAccept: (suggestion) => _acceptSuggestion(context, suggestion),
    );
  }
}

class _CoverageDetailView extends StatelessWidget {
  const _CoverageDetailView({
    required this.result,
    this.onNavigateToPosition,
  });

  final CoverageResult result;
  final void Function(List<String> moveSequence)? onNavigateToPosition;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _CoverageOverviewCard(result: result),
        const SizedBox(height: 12),
        if (result.tooShallowLeaves.isNotEmpty)
          _CoverageSection(
            title: 'Too shallow (${result.tooShallowLeaves.length})',
            color: AppColors.warning,
            items:
                result.tooShallowLeaves.map((leaf) => leaf.moveString).toList(),
            onItemTap: onNavigateToPosition == null
                ? null
                : (index) => onNavigateToPosition!(
                      result.tooShallowLeaves[index].moves,
                    ),
          ),
        if (result.tooDeepLeaves.isNotEmpty) ...[
          const SizedBox(height: 12),
          _CoverageSection(
            title: 'Too deep (${result.tooDeepLeaves.length})',
            color: AppColors.info,
            items: result.tooDeepLeaves.map((leaf) => leaf.moveString).toList(),
            onItemTap: onNavigateToPosition == null
                ? null
                : (index) => onNavigateToPosition!(
                      result.tooDeepLeaves[index].moves,
                    ),
          ),
        ],
        if (result.unaccountedMoves.isNotEmpty) ...[
          const SizedBox(height: 12),
          _CoverageSection(
            title: 'Unaccounted (${result.unaccountedMoves.length})',
            color: AppColors.danger,
            items: result.unaccountedMoves
                .map((um) => '${um.parentMoves.join(' ')} ${um.move}'.trim())
                .toList(),
            onItemTap: onNavigateToPosition == null
                ? null
                : (index) {
                    final um = result.unaccountedMoves[index];
                    onNavigateToPosition!([...um.parentMoves, um.move]);
                  },
          ),
        ],
      ],
    );
  }
}

class _CoverageOverviewCard extends StatelessWidget {
  const _CoverageOverviewCard({required this.result});

  final CoverageResult result;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[800]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${result.coveragePercent.toStringAsFixed(1)}% covered',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Target ${result.targetPercent.toStringAsFixed(0)}% '
            '(${result.rootGameCount} games at ${result.rootDescription})',
            style: TextStyle(fontSize: 12, color: Colors.grey[400]),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              _StatChip(
                label: 'Shallow',
                value: '${result.shallowPercent.toStringAsFixed(1)}%',
              ),
              _StatChip(
                label: 'Deep',
                value: '${result.deepPercent.toStringAsFixed(1)}%',
              ),
              _StatChip(
                label: 'Unaccounted',
                value: '${result.unaccountedPercent.toStringAsFixed(1)}%',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label: $value',
      style: TextStyle(fontSize: 11, color: Colors.grey[300]),
    );
  }
}

class _CoverageSection extends StatelessWidget {
  const _CoverageSection({
    required this.title,
    required this.color,
    required this.items,
    this.onItemTap,
  });

  final String title;
  final Color color;
  final List<String> items;
  final void Function(int index)? onItemTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.circle, size: 8, color: color),
            const SizedBox(width: 6),
            Text(
              title,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ...List.generate(items.length, (index) {
          final item = items[index];
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              item,
              style: TextStyle(fontSize: 11, color: Colors.grey[300]),
            ),
            onTap: onItemTap == null ? null : () => onItemTap!(index),
          );
        }),
      ],
    );
  }
}
