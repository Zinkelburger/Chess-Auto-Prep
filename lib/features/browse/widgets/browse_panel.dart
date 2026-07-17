/// Interactive browse panel — one-click add to repertoire.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../widgets/shortcut_tooltip.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../../services/coherence_service.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/features/browse/services/candidate_service.dart';
import '../../../widgets/layout/empty_state_placeholder.dart';
import 'candidate_row.dart';
import 'expanded_trap_list.dart';

class BrowsePanel extends StatefulWidget {
  final String fen;
  final List<String> pathFromRoot;
  final bool isOurTurn;
  final bool isWhiteRepertoire;
  final CandidateService candidateService;
  final BoardPreviewController boardPreview;
  final TrapIndexService? trapIndex;
  final int? expandedTrapIndex;
  final void Function(CandidateMove move)? onCandidateTap;
  final void Function(int index)? onExpandTraps;
  final void Function(TrapLineInfo trap)? onTrapGo;
  final VoidCallback? onBack;
  final VoidCallback? onRoot;
  final bool canUndo;
  final VoidCallback? onUndo;
  final CoherenceResult? coherenceResult;
  final List<String> currentMoves;

  const BrowsePanel({
    super.key,
    required this.fen,
    this.pathFromRoot = const [],
    required this.isOurTurn,
    required this.isWhiteRepertoire,
    required this.candidateService,
    required this.boardPreview,
    this.trapIndex,
    this.expandedTrapIndex,
    this.onCandidateTap,
    this.onExpandTraps,
    this.onTrapGo,
    this.onBack,
    this.onRoot,
    this.canUndo = false,
    this.onUndo,
    this.coherenceResult,
    this.currentMoves = const [],
  });

  @override
  State<BrowsePanel> createState() => _BrowsePanelState();
}

class _BrowsePanelState extends State<BrowsePanel> {
  List<CandidateMove> _candidates = [];
  List<CandidateMove> _rareCandidates = [];
  int _hoveredIndex = -1;
  bool _showRare = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadCandidates();
  }

  @override
  void didUpdateWidget(covariant BrowsePanel old) {
    super.didUpdateWidget(old);
    if (widget.fen != old.fen ||
        widget.pathFromRoot != old.pathFromRoot ||
        widget.currentMoves != old.currentMoves) {
      _loadCandidates();
    }
  }

  Future<void> _loadCandidates() async {
    setState(() => _isLoading = true);

    final path = widget.pathFromRoot.isNotEmpty
        ? widget.pathFromRoot
        : widget.currentMoves;

    final all = await widget.candidateService.getCandidates(
      fen: widget.fen,
      isOurTurn: widget.isOurTurn,
      playAsWhite: widget.isWhiteRepertoire,
      pathFromRoot: path,
    );

    if (!mounted) return;

    if (!widget.isOurTurn) {
      _candidates = all.where((m) => (m.dbFrequency ?? 0.05) >= 0.01).toList();
      _rareCandidates = all
          .where((m) => (m.dbFrequency ?? 0.05) < 0.01)
          .toList();
    } else {
      _candidates = all;
      _rareCandidates = [];
    }

    _hoveredIndex = -1;
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(theme),
        const Divider(height: 1),
        if (_isLoading)
          const Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (_candidates.isEmpty)
          _buildEmpty(theme)
        else
          Expanded(
            child: ListView.builder(
              itemCount:
                  _candidates.length +
                  (_rareCandidates.isNotEmpty ? 1 : 0) +
                  (_showRare ? _rareCandidates.length : 0),
              itemBuilder: (ctx, i) {
                if (i < _candidates.length) {
                  return _buildCandidateItem(i, _candidates[i]);
                }
                if (i == _candidates.length && _rareCandidates.isNotEmpty) {
                  return _buildRareToggle(theme);
                }
                final rareIdx = i - _candidates.length - 1;
                return _buildCandidateItem(
                  _candidates.length + 1 + rareIdx,
                  _rareCandidates[rareIdx],
                  isRare: true,
                );
              },
            ),
          ),
        _buildNavBar(theme),
      ],
    );
  }

  Widget _buildCandidateItem(
    int index,
    CandidateMove candidate, {
    bool isRare = false,
  }) {
    final trapCount = candidate.subtreeTrapCount ?? 0;
    final isExpanded = widget.expandedTrapIndex == index;

    return Column(
      children: [
        CandidateRow(
          candidate: candidate,
          isHovered: !isRare && _hoveredIndex == index,
          trapCount: trapCount,
          isTrapExpanded: isExpanded,
          coherenceHint: widget.coherenceResult != null
              ? coherenceHintForCandidateMove(
                  currentMoves: widget.currentMoves,
                  candidateSan: candidate.san,
                  playAsWhite: widget.isWhiteRepertoire,
                  result: widget.coherenceResult!,
                )
              : null,
          onExpandTraps: trapCount > 0 && widget.onExpandTraps != null
              ? () => widget.onExpandTraps!(index)
              : null,
          onTap: () => widget.onCandidateTap?.call(candidate),
          onHover: () {
            if (isRare) return;
            setState(() => _hoveredIndex = index);
            if (candidate.treeNode != null) {
              widget.boardPreview.setPreview(candidate.treeNode!.fen);
            }
          },
          onHoverEnd: () {
            if (isRare) return;
            setState(() => _hoveredIndex = -1);
            widget.boardPreview.clearPreview();
          },
        ),
        if (isExpanded && trapCount > 0 && widget.onTrapGo != null)
          ExpandedTrapList(
            candidate: candidate,
            trapIndex: widget.trapIndex,
            onTrapGo: widget.onTrapGo!,
          ),
      ],
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.explore, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            'CANDIDATE MOVES',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          Text('${_candidates.length} moves', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return const Expanded(
      child: EmptyStatePlaceholder(
        icon: Icons.search_off,
        iconSize: 48,
        title: 'No candidates at this position',
        subtitle: 'Generate a tree or connect to Lichess',
      ),
    );
  }

  Widget _buildRareToggle(ThemeData theme) {
    return InkWell(
      onTap: () => setState(() => _showRare = !_showRare),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(
              _showRare ? Icons.expand_less : Icons.expand_more,
              size: 16,
              color: AppColors.onSurfaceMuted,
            ),
            const SizedBox(width: 4),
            Text(
              'Rare moves (${_rareCandidates.length} more with < 1%)',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back, size: 14),
            label: const Text('Back'),
          ),
          TextButton.icon(
            onPressed: widget.onRoot,
            icon: const Icon(Icons.vertical_align_top, size: 14),
            label: const Text('Root'),
          ),
          if (widget.canUndo && widget.onUndo != null) ...[
            const Spacer(),
            ShortcutTooltip(
              description: 'Undo last add',
              shortcut: 'Ctrl+Z',
              child: TextButton.icon(
                onPressed: widget.onUndo,
                icon: const Icon(Icons.undo, size: 14),
                label: const Text('Undo'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
