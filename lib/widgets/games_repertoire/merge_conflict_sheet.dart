/// Pre-merge decision sheet for draft → repertoire conflicts.
///
/// Shown BEFORE anything is written. Each conflict is a position where the
/// user's games play a different move than their existing prep. The default
/// keeps the prep (that draft branch is skipped); choosing the games' move
/// imports the branch as extra lines. Nothing is removed either way.
///
/// Pops with the set of conflict indices to import, or null when cancelled
/// (the caller aborts the merge and returns to review).
library;

import 'package:flutter/material.dart';

import '../../services/games_repertoire/draft_merge_planner.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/movetext_builder.dart';

class MergeConflictSheet extends StatefulWidget {
  const MergeConflictSheet({super.key, required this.conflicts});

  final List<DraftConflict> conflicts;

  @override
  State<MergeConflictSheet> createState() => _MergeConflictSheetState();
}

class _MergeConflictSheetState extends State<MergeConflictSheet> {
  /// Conflict indices where the user picked their games' move.
  final Set<int> _importAlternatives = {};

  @override
  Widget build(BuildContext context) {
    final total = widget.conflicts.length;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.alt_route, color: AppColors.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$total conflict${total == 1 ? '' : 's'} with your prep',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Your games play a different move where your repertoire '
                'already has an answer. Keep your prep, or also import your '
                'move as extra lines — nothing is removed either way.',
                style: AppTextStyles.caption,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: total,
                itemBuilder: (context, i) => _conflictTile(i),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel merge'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () =>
                        Navigator.of(context).pop(_importAlternatives),
                    icon: const Icon(Icons.merge_type, size: 18),
                    label: const Text('Continue merge'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _conflictTile(int i) {
    final conflict = widget.conflicts[i];
    final importMine = _importAlternatives.contains(i);
    final lineLabel = _lineLabel(conflict.prefixSans);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: AppColors.surfaceElevated,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              lineLabel.isEmpty ? 'Starting position' : lineLabel,
              style: AppTextStyles.caption,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final san in conflict.repertoireSans)
                  _candidateChip(
                    san: san,
                    tag: 'prep',
                    selected: !importMine,
                    onTap: () => setState(() => _importAlternatives.remove(i)),
                  ),
                _candidateChip(
                  san: conflict.draftSan,
                  tag: 'yours',
                  selected: importMine,
                  onTap: () => setState(() => _importAlternatives.add(i)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              importMine
                  ? 'Your ${conflict.draftSan} will be added as an extra line.'
                  : 'Keeping your prep — this branch of the draft is skipped.',
              style: AppTextStyles.caption,
            ),
          ],
        ),
      ),
    );
  }

  Widget _candidateChip({
    required String san,
    required String tag,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ActionChip(
      onPressed: onTap,
      backgroundColor: selected
          ? AppColors.success.withValues(alpha: 0.18)
          : null,
      avatar: Icon(
        selected ? Icons.check_circle : Icons.circle_outlined,
        size: 16,
        color: selected ? AppColors.success : AppColors.onSurfaceDim,
      ),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(san, style: const TextStyle(fontWeight: FontWeight.w600)),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text('· $tag', style: AppTextStyles.caption),
          ),
        ],
      ),
    );
  }

  String _lineLabel(List<String> sans) =>
      buildNumberedMovetext(sans, compact: true);
}
