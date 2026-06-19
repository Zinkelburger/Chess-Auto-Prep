/// Inline draft review surface — lives in the repertoire screen's Lines tab
/// (which relabels to "Draft" while a session is active).
///
/// Shows the coverage-coloured games tree with prune, a summary header, a
/// min-games noise filter, and a Merge action. Merging folds the surviving
/// lines into the live repertoire and, if that creates a choice at one of your
/// decision points, pops the conflict sheet right away.
library;

import 'package:flutter/material.dart';

import '../../core/repertoire_controller.dart';
import '../../services/games_repertoire/games_draft.dart';
import '../../services/games_repertoire/draft_repertoire_writer.dart';
import '../../services/storage/storage_factory.dart';
import '../../theme/app_colors.dart';
import 'draft_tree_view.dart';
import 'merge_conflict_sheet.dart';

class DraftReviewPane extends StatefulWidget {
  const DraftReviewPane({
    super.key,
    required this.draft,
    required this.isWhite,
    required this.controller,
    required this.onClose,
    this.sourceLabel = '',
    this.onSelectLine,
  });

  final GamesDraft draft;
  final bool isWhite;
  final RepertoireController controller;

  /// Where the games came from (e.g. username), used to name a saved draft.
  final String sourceLabel;

  /// Called when the draft session ends (merged or discarded).
  final VoidCallback onClose;

  /// Reports the SAN path of a tapped row (e.g. to preview on the board).
  final void Function(List<String> sans)? onSelectLine;

  @override
  State<DraftReviewPane> createState() => _DraftReviewPaneState();
}

class _DraftReviewPaneState extends State<DraftReviewPane> {
  int _minGames = 2;
  bool _merging = false;

  Future<void> _merge() async {
    setState(() => _merging = true);
    final draftTree =
        widget.draft.materialize(filters: DraftFilters(minGames: _minGames));
    if (draftTree.isEmpty) {
      setState(() => _merging = false);
      _toast('Nothing to merge — every line was filtered out.');
      return;
    }
    final result =
        widget.controller.mergeDraft(draftTree, isWhite: widget.isWhite);
    if (!mounted) return;

    if (result.hasConflicts) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.surface,
        builder: (_) => MergeConflictSheet(
          controller: widget.controller,
          conflicts: result.conflicts,
        ),
      );
    } else {
      _toast('Merged ${result.addedMoves} new moves into your repertoire.');
    }
    if (mounted) widget.onClose();
  }

  Future<void> _saveAsDraft() async {
    final draftTree =
        widget.draft.materialize(filters: DraftFilters(minGames: _minGames));
    if (draftTree.isEmpty) {
      _toast('Nothing to save — every line was filtered out.');
      return;
    }
    final label = widget.sourceLabel.isEmpty ? 'games' : widget.sourceLabel;
    final side = widget.isWhite ? 'White' : 'Black';
    final stamp = DateTime.now().toIso8601String().split('T').first;
    final name = 'Draft $label $side $stamp';
    final content = draftToRepertoireFile(draftTree,
        name: name, isWhite: widget.isWhite);

    try {
      final storage = StorageFactory.instance;
      final path = await storage.repertoireFilePath(name);
      await storage.writeFile(path, content);
      if (!mounted) return;
      _toast('Saved "$name" — open it from the repertoire list.');
      widget.onClose();
    } catch (e) {
      _toast('Could not save draft: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final diff = widget.draft.diff;
    return Column(
      children: [
        // Header: title + close.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
          child: Row(
            children: [
              const Icon(Icons.download_done, size: 16),
              const SizedBox(width: 6),
              Text(
                'Draft from my games (${widget.isWhite ? 'White' : 'Black'})',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Discard draft',
                onPressed: _merging ? null : widget.onClose,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Wrap(spacing: 14, runSpacing: 2, children: [
            _stat('covered', diff.inRepertoireCount, AppColors.success),
            _stat('my off-book', diff.myDeviationCount, AppColors.warning),
            _stat('opp. gaps', diff.opponentDeviationCount, AppColors.danger),
          ]),
        ),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Align(alignment: Alignment.centerLeft, child: DraftLegend()),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              const Text('Min games', style: TextStyle(fontSize: 12)),
              Expanded(
                child: Slider(
                  value: _minGames.toDouble(),
                  min: 1,
                  max: 10,
                  divisions: 9,
                  label: '$_minGames',
                  onChanged: (v) => setState(() => _minGames = v.round()),
                ),
              ),
              Text('$_minGames+', style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: DraftTreeView(
            draft: widget.draft,
            minGames: _minGames,
            onSelectLine: widget.onSelectLine,
            onChanged: () => setState(() {}),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _merging
                      ? 'Merging…'
                      : 'Discard lines you don\'t want, then merge the rest in.',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.onSurfaceMuted),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _merging ? null : _saveAsDraft,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('Save'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _merging ? null : _merge,
                icon: const Icon(Icons.merge_type, size: 18),
                label: const Text('Merge'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stat(String label, int n, Color color) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 9, height: 9, color: color),
      const SizedBox(width: 5),
      Text('$n $label', style: const TextStyle(fontSize: 12)),
    ]);
  }
}
