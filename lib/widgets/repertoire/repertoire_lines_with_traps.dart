import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_suggestion_service.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import '../../features/eval_tree/widgets/eval_tree_tab.dart';
import '../../theme/app_colors.dart';
import '../coherence_panel.dart';
import 'package:chess_auto_prep/features/coverage/widgets/suggestion_panel.dart';
import '../repertoire_lines_browser.dart';
import 'package:chess_auto_prep/features/traps/widgets/traps_browser.dart';
import 'repertoire_analyze_props.dart';

/// Lines tab body with optional collapsible traps, coherence, and suggestions.
///
/// Used for compact analyze layout; wide layout uses [RepertoireAnalyzePane].
class RepertoireLinesWithTraps extends StatefulWidget {
  const RepertoireLinesWithTraps({
    super.key,
    required this.props,
  });

  final RepertoireAnalyzeProps props;

  @override
  State<RepertoireLinesWithTraps> createState() =>
      _RepertoireLinesWithTrapsState();
}

class _RepertoireLinesWithTrapsState extends State<RepertoireLinesWithTraps> {
  bool _trapsExpanded = false;
  bool _coherenceExpanded = false;
  bool _suggestionsExpanded = false;
  bool _evalTreeExpanded = false;

  RepertoireAnalyzeProps get _props => widget.props;

  Future<void> _acceptSuggestion(SuggestedLine suggestion) async {
    try {
      await _props.writer.acceptSuggestion(suggestion);
      if (mounted) {
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
      debugPrint('[RepertoireLinesWithTraps] Failed to accept suggestion: $e');
      if (mounted) {
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
    final props = _props;
    final hasAnyCollapsible = props.traps.isNotEmpty ||
        props.coherenceResult != null ||
        props.hasSuggestionMetrics ||
        props.currentRepertoire != null;

    return Column(
      children: [
        Expanded(
          flex: hasAnyCollapsible &&
                  (_trapsExpanded ||
                      _coherenceExpanded ||
                      _suggestionsExpanded ||
                      _evalTreeExpanded)
              ? 2
              : 1,
          child: RepertoireLinesBrowser(
            lines: props.lines,
            currentMoveSequence: props.currentMoveSequence,
            isExpanded: true,
            coverageResult: props.coverageResult,
            onCoveragePressed: props.onCoveragePressed,
            isCoverageRunning: props.isCoverageRunning,
            coverageProgress: props.coverageProgress,
            coverageProgressMessage: props.coverageProgressMessage,
            onLineSelected: props.onLineSelected,
            onLineRenamed: props.onLineRenamed,
            onNavigateToPosition: props.onNavigateToPosition,
            tree: props.tree,
            fenMap: props.fenMap,
            isWhiteRepertoire: props.isWhiteRepertoire,
            traps: props.traps,
            coherenceResult: props.coherenceResult,
            navigationStack: props.navigationStack,
          ),
        ),
        if (props.traps.isNotEmpty) ...[
          const Divider(height: 1),
          _buildCollapsibleHeader(
            icon: Icons.warning_amber_rounded,
            iconColor: AppColors.warning,
            label: 'Traps (${props.traps.length})',
            isExpanded: _trapsExpanded,
            onTap: () => setState(() => _trapsExpanded = !_trapsExpanded),
          ),
          if (_trapsExpanded)
            Expanded(
              flex: 1,
              child: TrapsBrowser(
                traps: props.traps,
                currentMoveSequence: props.currentMoveSequence,
                boardPreview: props.boardPreview,
                onTrapSelected: props.onTrapSelected,
                metrics: TrapIndexService(props.traps).metrics,
                onStartTour: props.onStartTrapTour,
              ),
            ),
        ],
        if (props.coherenceResult != null) ...[
          const Divider(height: 1),
          _buildCollapsibleHeader(
            icon: Icons.hub,
            iconColor: AppColors.maia,
            label:
                'Coherence (${props.coherenceResult!.globalCoherence.toStringAsFixed(2)})',
            isExpanded: _coherenceExpanded,
            onTap: () =>
                setState(() => _coherenceExpanded = !_coherenceExpanded),
          ),
          if (_coherenceExpanded)
            Expanded(
              flex: 1,
              child: CoherencePanel(
                result: props.coherenceResult!,
                lineNames: props.lineNames,
              ),
            ),
        ],
        if (props.hasSuggestionMetrics) ...[
          const Divider(height: 1),
          _buildCollapsibleHeader(
            icon: Icons.auto_fix_high,
            iconColor: AppColors.evalPositive,
            label: 'Coverage Suggestions',
            isExpanded: _suggestionsExpanded,
            onTap: () =>
                setState(() => _suggestionsExpanded = !_suggestionsExpanded),
          ),
          if (_suggestionsExpanded)
            Expanded(
              flex: 1,
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
                onAccept: _acceptSuggestion,
              ),
            ),
        ],
        if (props.currentRepertoire != null) ...[
          const Divider(height: 1),
          _buildCollapsibleHeader(
            icon: Icons.insights,
            iconColor: AppColors.evalPositive,
            label: 'Eval Tree',
            isExpanded: _evalTreeExpanded,
            onTap: () => setState(() => _evalTreeExpanded = !_evalTreeExpanded),
          ),
          if (_evalTreeExpanded)
            Expanded(
              flex: 1,
              child: EvalTreeTab(
                currentRepertoire: props.currentRepertoire,
                isWhiteRepertoire: props.isWhiteRepertoire,
                generatedTree: props.tree,
                treeResetCounter: props.treeResetCounter,
                onPositionSelected: props.onEvalTreePositionSelected,
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildCollapsibleHeader({
    required IconData icon,
    required Color iconColor,
    required String label,
    required bool isExpanded,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 16, color: iconColor),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey[300],
              ),
            ),
            const Spacer(),
            Icon(
              isExpanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: Colors.grey[500],
            ),
          ],
        ),
      ),
    );
  }
}
