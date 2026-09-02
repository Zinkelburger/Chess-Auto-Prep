/// Inline draft review surface — lives in the repertoire screen's Lines tab
/// (which relabels to "Draft" while a session is active).
///
/// Shows the coverage-coloured games tree with prune, a summary header, a
/// min-games noise filter, and two exits:
///   • Merge into repertoire — plans against the FULL repertoire, resolves
///     any prep conflicts up front (see [MergeConflictSheet]), then appends
///     the new lines to the repertoire file and reloads. Nothing existing is
///     rewritten or removed.
///   • Save as new file — writes the surviving lines as a fresh, re-openable
///     repertoire (collision-proof name).
library;

import 'package:flutter/material.dart';

import '../../core/repertoire_controller.dart';
import '../../services/games_repertoire/draft_merge_planner.dart';
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

  /// Why merging is impossible right now, or null when it's allowed.
  /// (Saving as a new file works in every one of these cases.)
  String? get _mergeBlockedReason {
    final c = widget.controller;
    if (c.currentRepertoire == null) {
      return 'No repertoire file is loaded — use "Save as new file" instead.';
    }
    if (c.startingFen != null) {
      return 'This repertoire starts from a custom position, but game lines '
          'start from move 1. Use "Save as new file" instead.';
    }
    if (c.isRepertoireWhite != widget.isWhite) {
      final draftSide = widget.isWhite ? 'White' : 'Black';
      final repSide = c.isRepertoireWhite ? 'White' : 'Black';
      return 'This draft is for $draftSide but the repertoire is for '
          '$repSide. Use "Save as new file" instead.';
    }
    return null;
  }

  Future<void> _merge() async {
    setState(() => _merging = true);
    try {
      final draftTree = widget.draft.materialize(
        filters: DraftFilters(minGames: _minGames),
      );
      if (draftTree.isEmpty) {
        _toast('Nothing to merge — every line was filtered out.');
        return;
      }

      final plan = planDraftMerge(
        repertoire: widget.controller.buildRepertoireMoveTree(),
        draft: draftTree,
        isWhite: widget.isWhite,
      );
      if (plan.isEmpty) {
        _toast('Your repertoire already covers every line in this draft.');
        return;
      }

      var importAlternatives = <int>{};
      if (plan.hasConflicts) {
        final decision = await showModalBottomSheet<Set<int>>(
          context: context,
          isScrollControlled: true,
          backgroundColor: AppColors.surface,
          builder: (_) => MergeConflictSheet(conflicts: plan.conflicts),
        );
        if (decision == null) return; // Cancelled — back to review.
        importAlternatives = decision;
      }

      final lines = applyConflictDecisions(
        plan,
        importAlternatives: importAlternatives,
      );
      if (lines.isEmpty) {
        _toast('Nothing left to add after keeping your prep.');
        return;
      }

      final result = await widget.controller.appendDraftLines(
        lines,
        sourceLabel: widget.sourceLabel,
      );
      if (!mounted) return;
      if (result.added == 0) {
        _toast('Could not write to the repertoire file.');
        return;
      }
      final name = widget.controller.currentRepertoire?.name ?? 'repertoire';
      final gaps = result.needAnswer;
      final gapNote = gaps > 0
          ? ' — $gaps need${gaps == 1 ? 's' : ''} an answer'
          : '';
      _toast(
        'Added ${result.added} line${result.added == 1 ? '' : 's'} '
        'to "$name"$gapNote.',
      );
      widget.onClose();
    } finally {
      if (mounted) setState(() => _merging = false);
    }
  }

  Future<void> _saveAsDraft() async {
    final draftTree = widget.draft.materialize(
      filters: DraftFilters(minGames: _minGames),
    );
    if (draftTree.isEmpty) {
      _toast('Nothing to save — every line was filtered out.');
      return;
    }
    final label = widget.sourceLabel.isEmpty ? 'games' : widget.sourceLabel;
    final side = widget.isWhite ? 'White' : 'Black';
    final stamp = DateTime.now().toIso8601String().split('T').first;
    final base = 'Draft $label $side $stamp';

    try {
      final storage = StorageFactory.instance;
      var name = base;
      var path = await storage.repertoireFilePath(name);
      for (var n = 2; await storage.fileExists(path); n++) {
        name = '$base ($n)';
        path = await storage.repertoireFilePath(name);
      }
      final content = draftToRepertoireFile(
        draftTree,
        name: name,
        isWhite: widget.isWhite,
      );
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final diff = widget.draft.diff;
    final blocked = _mergeBlockedReason;
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
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
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
          child: Wrap(
            spacing: 14,
            runSpacing: 2,
            children: [
              _stat('covered', diff.inRepertoireCount, AppColors.success),
              _stat('my off-book', diff.myDeviationCount, AppColors.warning),
              _stat('opp. gaps', diff.opponentDeviationCount, AppColors.danger),
            ],
          ),
        ),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Align(alignment: Alignment.centerLeft, child: DraftLegend()),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 2, 12, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Tap a line to expand · long-press to preview on the board · 🗑 discards it',
              style: TextStyle(fontSize: 12, color: AppColors.onSurfaceDim),
            ),
          ),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text(
                  _merging
                      ? 'Merging…'
                      : blocked ??
                            'Discard lines you don\'t want, then merge the '
                                'rest in. Merging only adds new lines — '
                                'nothing is removed.',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.onSurfaceMuted,
                  ),
                ),
              ),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _merging ? null : _saveAsDraft,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('Save as new file'),
                  ),
                  FilledButton.icon(
                    onPressed: (_merging || blocked != null) ? null : _merge,
                    icon: const Icon(Icons.merge_type, size: 18),
                    label: const Text('Merge into repertoire'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stat(String label, int n, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 9, height: 9, color: color),
        const SizedBox(width: 5),
        Text('$n $label', style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
