/// Surfaces merge conflicts after folding a games-draft into the repertoire.
///
/// A conflict is a position where *I* now have more than one candidate move
/// (e.g. the draft says I played Bc4 but my repertoire already had Nf3). Both
/// live in the tree as siblings; here the user picks which is the mainline and
/// which becomes the sideline, via the existing `makeMainLine` gesture.
library;

import 'package:flutter/material.dart';

import '../../core/repertoire_controller.dart';
import '../../models/move_tree.dart';
import '../../services/games_repertoire/repertoire_merge.dart';
import '../../theme/app_colors.dart';

class MergeConflictSheet extends StatefulWidget {
  const MergeConflictSheet({
    super.key,
    required this.controller,
    required this.conflicts,
  });

  final RepertoireController controller;
  final List<MergeConflict> conflicts;

  @override
  State<MergeConflictSheet> createState() => _MergeConflictSheetState();
}

class _MergeConflictSheetState extends State<MergeConflictSheet> {
  final Set<int> _resolved = {};

  List<MoveNode> _childrenAt(TreePath path) {
    final tree = widget.controller.tree;
    return path.isEmpty ? tree.roots : (tree.nodeAt(path)?.children ?? []);
  }

  void _makeMainline(TreePath parentPath, int childIndex, int conflictIndex) {
    widget.controller.makeMainLine(parentPath.child(childIndex));
    setState(() => _resolved.add(conflictIndex));
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.conflicts.length;
    final done = _resolved.length;
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
                      '$total decision${total == 1 ? '' : 's'} to make'
                      '  ·  $done resolved',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(done >= total ? 'Done' : 'Later'),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Your games introduced a different move where you already had '
                'prep. Pick which one is your main line.',
                style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
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
          ],
        ),
      ),
    );
  }

  Widget _conflictTile(int i) {
    final conflict = widget.conflicts[i];
    final children = _childrenAt(conflict.parentPath);
    final resolved = _resolved.contains(i);
    final lineLabel = _lineLabel(conflict.parentPath);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: resolved ? AppColors.surfaceContainer : AppColors.surfaceElevated,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (resolved)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(
                      Icons.check_circle,
                      size: 16,
                      color: AppColors.success,
                    ),
                  ),
                Expanded(
                  child: Text(
                    lineLabel.isEmpty ? 'Starting position' : lineLabel,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var idx = 0; idx < children.length; idx++)
                  _candidateChip(
                    san: children[idx].san,
                    isMainline: idx == 0,
                    isFromGames: children[idx].san == conflict.draftSan,
                    onTap: () => _makeMainline(conflict.parentPath, idx, i),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _candidateChip({
    required String san,
    required bool isMainline,
    required bool isFromGames,
    required VoidCallback onTap,
  }) {
    return ActionChip(
      onPressed: onTap,
      backgroundColor: isMainline
          ? AppColors.success.withValues(alpha: 0.18)
          : null,
      avatar: Icon(
        isMainline ? Icons.star : Icons.star_border,
        size: 16,
        color: isMainline ? AppColors.success : AppColors.onSurfaceDim,
      ),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(san, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (isFromGames)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Text(
                '· yours',
                style: TextStyle(fontSize: 10, color: AppColors.onSurfaceDim),
              ),
            ),
        ],
      ),
    );
  }

  String _lineLabel(TreePath parentPath) {
    final sans = widget.controller.tree.sanSequenceAt(parentPath);
    final buf = StringBuffer();
    for (var i = 0; i < sans.length; i++) {
      if (i.isEven) buf.write('${(i ~/ 2) + 1}.');
      buf.write('${sans[i]} ');
    }
    return buf.toString().trim();
  }
}
