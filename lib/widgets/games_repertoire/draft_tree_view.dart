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
import '../opening_tree/win_draw_loss_bar.dart';

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
    this.autoCollapseDepth = 1,
  });

  final GamesDraft draft;

  /// Called after a prune so the host can rebuild summaries.
  final VoidCallback onChanged;

  /// Selecting a row reports the SAN path from the root (e.g. for a board
  /// preview).
  final void Function(List<String> sans)? onSelectLine;

  /// Hide moves played in fewer than this many games (noise control).
  final int minGames;

  /// Nodes at this depth (0-based ply from the root) and deeper start
  /// collapsed, so the tree opens showing only the first plies instead of a
  /// fully-expanded wall. Tap a row to drill in.
  final int autoCollapseDepth;

  @override
  State<DraftTreeView> createState() => _DraftTreeViewState();
}

class _DraftTreeViewState extends State<DraftTreeView> {
  final Set<OpeningTreeNode> _collapsed = {};

  @override
  void initState() {
    super.initState();
    _seedCollapsed(widget.draft.tree.root, 0);
  }

  @override
  void didUpdateWidget(covariant DraftTreeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A fresh draft (or new tree) reseeds the collapse state from scratch.
    if (!identical(oldWidget.draft, widget.draft) ||
        !identical(oldWidget.draft.tree, widget.draft.tree)) {
      _collapsed.clear();
      _seedCollapsed(widget.draft.tree.root, 0);
    }
  }

  /// Collapse every node at [DraftTreeView.autoCollapseDepth] or deeper that has
  /// children, so deep lines are folded away on first paint.
  void _seedCollapsed(OpeningTreeNode node, int depth) {
    for (final child in node.sortedChildren) {
      if (depth >= widget.autoCollapseDepth && child.sortedChildren.isNotEmpty) {
        _collapsed.add(child);
      }
      _seedCollapsed(child, depth + 1);
    }
  }

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

    // Tapping the row drills in (expand/collapse) when there are children;
    // leaf rows preview the line instead. Long-press always previews.
    return InkWell(
      onTap: hasChildren ? onToggle : onSelect,
      onLongPress: onSelect,
      child: Padding(
        padding: EdgeInsets.fromLTRB(8.0 + depth * 16, 3, 4, 3),
        child: Row(
          children: [
            // Expand/collapse affordance (indicator only — the whole row taps).
            SizedBox(
              width: 18,
              child: hasChildren
                  ? Icon(
                      collapsed ? Icons.chevron_right : Icons.expand_more,
                      size: 18,
                      color: AppColors.onSurfaceDim,
                    )
                  : null,
            ),
            // Coverage status dot.
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            // Move label.
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: status == DraftMoveStatus.inRepertoire
                      ? FontWeight.normal
                      : FontWeight.w600,
                  color: status == DraftMoveStatus.inRepertoire
                      ? AppColors.onSurfaceMuted
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Games count.
            SizedBox(
              width: 30,
              child: Text(
                '${node.gamesPlayed}',
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 11, color: AppColors.onSurfaceDim),
              ),
            ),
            const SizedBox(width: 8),
            // W/D/L bar (shared with the opening explorer).
            SizedBox(
              width: 64,
              child: WinDrawLossBar(
                wins: node.wins,
                draws: node.draws,
                losses: node.losses,
                height: 12,
              ),
            ),
            const SizedBox(width: 8),
            // Win %.
            SizedBox(
              width: 34,
              child: Text(
                '$winPct%',
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 11, color: AppColors.onSurfaceMuted),
              ),
            ),
            // Discard subtree.
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
