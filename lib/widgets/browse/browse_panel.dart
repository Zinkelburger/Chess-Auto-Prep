/// Interactive browse panel — one-click add to repertoire.
library;

import 'package:flutter/material.dart';

import '../../services/board_preview_controller.dart';
import '../../services/candidate_service.dart';
import 'candidate_row.dart';

class BrowsePanel extends StatefulWidget {
  final String fen;
  final bool isOurTurn;
  final bool isWhiteRepertoire;
  final CandidateService candidateService;
  final BoardPreviewController boardPreview;
  final void Function(CandidateMove move)? onCandidateTap;
  final VoidCallback? onBack;
  final VoidCallback? onRoot;

  const BrowsePanel({
    super.key,
    required this.fen,
    required this.isOurTurn,
    required this.isWhiteRepertoire,
    required this.candidateService,
    required this.boardPreview,
    this.onCandidateTap,
    this.onBack,
    this.onRoot,
  });

  @override
  State<BrowsePanel> createState() => _BrowsePanelState();
}

class _BrowsePanelState extends State<BrowsePanel> {
  List<CandidateMove> _candidates = [];
  List<CandidateMove> _rareCandidates = [];
  int _hoveredIndex = -1;
  bool _showRare = false;

  @override
  void initState() {
    super.initState();
    _loadCandidates();
  }

  @override
  void didUpdateWidget(covariant BrowsePanel old) {
    super.didUpdateWidget(old);
    if (widget.fen != old.fen) {
      _loadCandidates();
    }
  }

  void _loadCandidates() {
    final all = widget.candidateService.getTreeCandidates(
      fen: widget.fen,
      isOurTurn: widget.isOurTurn,
      playAsWhite: widget.isWhiteRepertoire,
    );

    if (!widget.isOurTurn) {
      _candidates =
          all.where((m) => (m.dbFrequency ?? 0.05) >= 0.01).toList();
      _rareCandidates =
          all.where((m) => (m.dbFrequency ?? 0.05) < 0.01).toList();
    } else {
      _candidates = all;
      _rareCandidates = [];
    }

    _hoveredIndex = -1;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(theme),
        const Divider(height: 1),
        if (_candidates.isEmpty)
          _buildEmpty(theme)
        else
          Expanded(
            child: ListView.builder(
              itemCount: _candidates.length +
                  (_rareCandidates.isNotEmpty ? 1 : 0) +
                  (_showRare ? _rareCandidates.length : 0),
              itemBuilder: (ctx, i) {
                if (i < _candidates.length) {
                  return CandidateRow(
                    candidate: _candidates[i],
                    isOurTurn: widget.isOurTurn,
                    isHovered: _hoveredIndex == i,
                    onTap: () => widget.onCandidateTap
                        ?.call(_candidates[i]),
                    onHover: () {
                      setState(() => _hoveredIndex = i);
                      if (_candidates[i].treeNode != null) {
                        widget.boardPreview
                            .setPreview(_candidates[i].treeNode!.fen);
                      }
                    },
                    onHoverEnd: () {
                      setState(() => _hoveredIndex = -1);
                      widget.boardPreview.clearPreview();
                    },
                  );
                }
                if (i == _candidates.length &&
                    _rareCandidates.isNotEmpty) {
                  return _buildRareToggle(theme);
                }
                final rareIdx =
                    i - _candidates.length - 1;
                return CandidateRow(
                  candidate: _rareCandidates[rareIdx],
                  isOurTurn: widget.isOurTurn,
                  isHovered: false,
                  onTap: () => widget.onCandidateTap
                      ?.call(_rareCandidates[rareIdx]),
                  onHover: () {},
                  onHoverEnd: () {},
                );
              },
            ),
          ),
        _buildNavBar(theme),
      ],
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(
            widget.isOurTurn
                ? Icons.person
                : Icons.people,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            widget.isOurTurn
                ? 'YOUR RESPONSE'
                : 'OPPONENT MOVES',
            style: theme.textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          Text('${_candidates.length} moves',
              style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Expanded(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off,
                size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 8),
            Text('No candidates at this position',
                style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text('Generate a tree or connect to Lichess',
                style: theme.textTheme.bodySmall),
          ],
        ),
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
              _showRare
                  ? Icons.expand_less
                  : Icons.expand_more,
              size: 16,
              color: Colors.grey,
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
        ],
      ),
    );
  }
}
