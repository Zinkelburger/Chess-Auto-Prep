/// Coverage-annotated, prunable view of a [GamesDraft] tree.
///
/// This is the Draft tab's centrepiece: the user's own games rendered as an
/// opening tree, each move coloured by how it stands against the active
/// repertoire (green = already covered, amber = my off-book move, red =
/// opponent move with no answer, grey = beyond the book). A discard button on
/// every row is the "erase a whole swathe" gesture — pruning a node drops its
/// entire subtree.
library;

import 'package:flutter/material.dart';

import '../../models/opening_tree.dart';
import '../../services/games_repertoire/games_draft.dart';
import '../../services/games_repertoire/repertoire_diff.dart';
import '../../theme/app_colors.dart';

Color statusColor(DraftMoveStatus status) {
  switch (status) {
    case DraftMoveStatus.inRepertoire:
      return AppColors.success;
    case DraftMoveStatus.myDeviation:
      return AppColors.warning;
    case DraftMoveStatus.opponentDeviation:
      return AppColors.danger;
    case DraftMoveStatus.beyondBook:
      return AppColors.onSurfaceDim;
  }
}

String statusLabel(DraftMoveStatus status) {
  switch (status) {
    case DraftMoveStatus.inRepertoire:
      return 'In repertoire';
    case DraftMoveStatus.myDeviation:
      return 'My move — off book';
    case DraftMoveStatus.opponentDeviation:
      return 'Opponent — no answer';
    case DraftMoveStatus.beyondBook:
      return 'Beyond book';
  }
}

class DraftTreeView extends StatefulWidget {
  const DraftTreeView({
    super.key,
    required this.draft,
    required this.onChanged,
    this.onSelectLine,
    this.minGames = 1,
  });

  final GamesDraft draft;

  /// Called after a prune so the host can rebuild summaries.
  final VoidCallback onChanged;

  /// Selecting a row reports the SAN path from the root (e.g. for a board
  /// preview).
  final void Function(List<String> sans)? onSelectLine;

  /// Hide moves played in fewer than this many games (noise control).
  final int minGames;

  @override
  State<DraftTreeView> createState() => _DraftTreeViewState();
}

class _DraftTreeViewState extends State<DraftTreeView> {
  final Set<OpeningTreeNode> _collapsed = {};

  void _prune(OpeningTreeNode node) {
    setState(() => widget.draft.prune(node));
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    _build(widget.draft.tree.root, const [], 0, rows);
    if (rows.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No lines left — adjust filters or rebuild.'),
        ),
      );
    }
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: rows);
  }

  void _build(
    OpeningTreeNode node,
    List<String> pathSans,
    int depth,
    List<Widget> out,
  ) {
    final children = node.sortedChildren
        .where((c) => c.gamesPlayed >= widget.minGames)
        .toList();
    for (final child in children) {
      final sans = [...pathSans, child.move];
      final info = widget.draft.diff[child];
      final collapsed = _collapsed.contains(child);
      final hasKids = child.sortedChildren
          .any((c) => c.gamesPlayed >= widget.minGames);

      out.add(_DraftRow(
        node: child,
        sans: sans,
        depth: depth,
        info: info,
        hasChildren: hasKids,
        collapsed: collapsed,
        onToggle: hasKids
            ? () => setState(() {
                  if (!_collapsed.remove(child)) _collapsed.add(child);
                })
            : null,
        onSelect: () => widget.onSelectLine?.call(sans),
        onPrune: () => _prune(child),
      ));

      if (!collapsed) _build(child, sans, depth + 1, out);
    }
  }
}

class _DraftRow extends StatelessWidget {
  const _DraftRow({
    required this.node,
    required this.sans,
    required this.depth,
    required this.info,
    required this.hasChildren,
    required this.collapsed,
    required this.onToggle,
    required this.onSelect,
    required this.onPrune,
  });

  final OpeningTreeNode node;
  final List<String> sans;
  final int depth;
  final DraftMoveInfo? info;
  final bool hasChildren;
  final bool collapsed;
  final VoidCallback? onToggle;
  final VoidCallback onSelect;
  final VoidCallback onPrune;

  @override
  Widget build(BuildContext context) {
    final status = info?.status ?? DraftMoveStatus.beyondBook;
    final color = statusColor(status);
    final ply = sans.length;
    final moveNumber = (ply + 1) ~/ 2;
    final isWhiteMove = ply.isOdd;
    final label =
        isWhiteMove ? '$moveNumber. ${node.move}' : '$moveNumber… ${node.move}';
    final winPct = (node.winRate * 100).round();

    return InkWell(
      onTap: onSelect,
      child: Padding(
        padding: EdgeInsets.fromLTRB(8.0 + depth * 16, 2, 8, 2),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: hasChildren
                  ? IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      iconSize: 18,
                      icon: Icon(collapsed
                          ? Icons.chevron_right
                          : Icons.expand_more),
                      onPressed: onToggle,
                    )
                  : null,
            ),
            Container(width: 4, height: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontFeatures: const [],
                  fontWeight: status == DraftMoveStatus.inRepertoire
                      ? FontWeight.normal
                      : FontWeight.w600,
                  color: status == DraftMoveStatus.inRepertoire
                      ? AppColors.onSurfaceMuted
                      : null,
                ),
              ),
            ),
            Text(
              '${node.gamesPlayed}g · $winPct%',
              style: const TextStyle(
                  fontSize: 11, color: AppColors.onSurfaceDim),
            ),
            const SizedBox(width: 4),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              iconSize: 16,
              tooltip: 'Discard this line and everything after it',
              icon: const Icon(Icons.delete_outline),
              color: AppColors.onSurfaceDim,
              onPressed: onPrune,
            ),
          ],
        ),
      ),
    );
  }
}

/// A compact legend explaining the row colours.
class DraftLegend extends StatelessWidget {
  const DraftLegend({super.key});

  @override
  Widget build(BuildContext context) {
    Widget chip(DraftMoveStatus s) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10, color: statusColor(s)),
            const SizedBox(width: 4),
            Text(statusLabel(s),
                style: const TextStyle(
                    fontSize: 11, color: AppColors.onSurfaceMuted)),
          ]),
        );
    return Wrap(children: [
      chip(DraftMoveStatus.inRepertoire),
      chip(DraftMoveStatus.myDeviation),
      chip(DraftMoveStatus.opponentDeviation),
      chip(DraftMoveStatus.beyondBook),
    ]);
  }
}
