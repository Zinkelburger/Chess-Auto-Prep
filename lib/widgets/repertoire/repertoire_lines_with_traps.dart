import 'package:flutter/material.dart';

import '../../models/build_tree_node.dart';
import '../../models/repertoire_line.dart';
import '../../models/trap_line_info.dart';
import '../../services/board_preview_controller.dart';
import '../../services/coherence_service.dart';
import '../../services/coverage_service.dart';
import '../../services/coverage_suggestion_service.dart';
import '../../services/generation/fen_map.dart';
import '../../services/navigation_stack.dart';
import '../../theme/app_colors.dart';
import '../coherence_panel.dart';
import '../coverage/suggestion_panel.dart';
import '../repertoire_lines_browser.dart';
import '../traps_browser.dart';

/// Lines tab body with optional collapsible traps, coherence, and suggestions.
class RepertoireLinesWithTraps extends StatefulWidget {
  const RepertoireLinesWithTraps({
    super.key,
    required this.lines,
    required this.currentMoveSequence,
    this.coverageResult,
    this.onCoveragePressed,
    this.isCoverageRunning = false,
    this.coverageProgress,
    this.coverageProgressMessage,
    required this.onLineSelected,
    required this.onLineRenamed,
    this.onNavigateToPosition,
    required this.traps,
    required this.onTrapSelected,
    this.tree,
    this.fenMap,
    this.isWhiteRepertoire = true,
    this.coherenceResult,
    this.navigationStack,
    this.boardPreview,
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

  @override
  State<RepertoireLinesWithTraps> createState() =>
      _RepertoireLinesWithTrapsState();
}

class _RepertoireLinesWithTrapsState extends State<RepertoireLinesWithTraps> {
  bool _trapsExpanded = false;
  bool _coherenceExpanded = false;
  bool _suggestionsExpanded = false;

  @override
  Widget build(BuildContext context) {
    final hasAnyCollapsible = widget.traps.isNotEmpty ||
        widget.coherenceResult != null ||
        (widget.coverageResult != null && widget.tree != null);

    return Column(
      children: [
        Expanded(
          flex: hasAnyCollapsible &&
                  (_trapsExpanded ||
                      _coherenceExpanded ||
                      _suggestionsExpanded)
              ? 2
              : 1,
          child: RepertoireLinesBrowser(
            lines: widget.lines,
            currentMoveSequence: widget.currentMoveSequence,
            isExpanded: true,
            coverageResult: widget.coverageResult,
            onCoveragePressed: widget.onCoveragePressed,
            isCoverageRunning: widget.isCoverageRunning,
            coverageProgress: widget.coverageProgress,
            coverageProgressMessage: widget.coverageProgressMessage,
            onLineSelected: widget.onLineSelected,
            onLineRenamed: widget.onLineRenamed,
            onNavigateToPosition: widget.onNavigateToPosition,
            tree: widget.tree,
            fenMap: widget.fenMap,
            isWhiteRepertoire: widget.isWhiteRepertoire,
            traps: widget.traps,
            coherenceResult: widget.coherenceResult,
            navigationStack: widget.navigationStack,
          ),
        ),
        if (widget.traps.isNotEmpty) ...[
          const Divider(height: 1),
          _buildCollapsibleHeader(
            icon: Icons.warning_amber_rounded,
            iconColor: AppColors.warning,
            label: 'Traps (${widget.traps.length})',
            isExpanded: _trapsExpanded,
            onTap: () => setState(() => _trapsExpanded = !_trapsExpanded),
          ),
          if (_trapsExpanded)
            Expanded(
              flex: 1,
              child: TrapsBrowser(
                traps: widget.traps,
                currentMoveSequence: widget.currentMoveSequence,
                onTrapSelected: widget.onTrapSelected,
              ),
            ),
        ],
        if (widget.coherenceResult != null) ...[
          const Divider(height: 1),
          _buildCollapsibleHeader(
            icon: Icons.hub,
            iconColor: AppColors.maia,
            label:
                'Coherence (${widget.coherenceResult!.globalCoherence.toStringAsFixed(2)})',
            isExpanded: _coherenceExpanded,
            onTap: () =>
                setState(() => _coherenceExpanded = !_coherenceExpanded),
          ),
          if (_coherenceExpanded)
            Expanded(
              flex: 1,
              child: CoherencePanel(
                result: widget.coherenceResult!,
                lineNames: {
                  for (final l in widget.lines) l.id: l.name,
                },
              ),
            ),
        ],
        if (widget.coverageResult != null && widget.tree != null) ...[
          const Divider(height: 1),
          _buildCollapsibleHeader(
            icon: Icons.auto_fix_high,
            iconColor: AppColors.evalPositive,
            label: 'Coverage Suggestions',
            isExpanded: _suggestionsExpanded,
            onTap: () => setState(
                () => _suggestionsExpanded = !_suggestionsExpanded),
          ),
          if (_suggestionsExpanded)
            Expanded(
              flex: 1,
              child: SuggestionPanel(
                service: CoverageSuggestionService(
                  coverage: widget.coverageResult!,
                  tree: widget.tree,
                  fenMap: widget.fenMap,
                ),
                playAsWhite: widget.isWhiteRepertoire,
                boardPreview:
                    widget.boardPreview ?? BoardPreviewController(),
                currentCoverage: widget.coverageResult!.coveragePercent,
                onAccept: (suggestion) {
                  // Add the suggested line to the repertoire
                  // This is handled by the parent
                },
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
