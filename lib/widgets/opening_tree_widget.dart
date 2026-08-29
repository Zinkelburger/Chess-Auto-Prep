/// Opening tree widget - Interactive move tree explorer
/// Similar to openingtree.com's interface
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'package:flutter/services.dart';
import '../models/opening_tree.dart';
import '../models/position_analysis.dart';
import '../models/repertoire_line.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../utils/app_messages.dart';
import '../utils/pgn_utils.dart' as pgn_utils;
import 'opening_tree/coverage_annotation.dart';
import 'opening_tree/opening_tree_move_row.dart';
import '../utils/fen_utils.dart';
import '../utils/movetext_builder.dart';

class OpeningTreeWidget extends StatefulWidget {
  final OpeningTree tree;
  final Function(String fen)? onPositionSelected;
  final Function(String move)? onMoveSelected;

  /// When set, the move-path header becomes clickable: tapping a move jumps
  /// to that ply (0 = starting position). When null the path is plain text.
  final Function(int ply)? onPathPlySelected;
  final Function(String searchTerm)? onSearchChanged;
  final Function(RepertoireLine line)? onLineSelected;
  final VoidCallback? onGoBack;
  final VoidCallback? onGoForward;
  final List<RepertoireLine> repertoireLines;
  final List<String> currentMoveSequence;
  final bool showPgnSearch;
  final CoverageResult? coverageResult;

  /// Games at the current tree position — used to offer "View PGN" at leaves.
  final List<GameInfo> gamesAtPosition;

  /// Called when the user taps "View PGN" for a game at a leaf node.
  final Function(GameInfo game)? onViewGamePgn;

  /// How win/draw/loss stats are colored (see [WdlPerspective]).
  final WdlPerspective wdlPerspective;

  /// Color the analyzed player (the tree's protagonist) plays in these
  /// games. When set, positions are annotated with the chance the
  /// protagonist steers the game there (see [ReachEstimate]); null hides
  /// the annotation. Independent of [wdlPerspective], which for
  /// player-analysis trees describes whose perspective the W/D/L counts
  /// use, not the player's color.
  final bool? protagonistIsWhite;

  const OpeningTreeWidget({
    super.key,
    required this.tree,
    this.onPositionSelected,
    this.onMoveSelected,
    this.onPathPlySelected,
    this.onSearchChanged,
    this.onLineSelected,
    this.onGoBack,
    this.onGoForward,
    this.repertoireLines = const [],
    this.currentMoveSequence = const [],
    this.showPgnSearch = false,
    this.coverageResult,
    this.gamesAtPosition = const [],
    this.onViewGamePgn,
    this.wdlPerspective = WdlPerspective.playerIsWhite,
    this.protagonistIsWhite,
    this.onHoverMove,
  });

  /// The SAN under the pointer in the move list, or null once it leaves —
  /// so the host can echo the move as an arrow on the board.
  final ValueChanged<String?>? onHoverMove;

  @override
  State<OpeningTreeWidget> createState() => _OpeningTreeWidgetState();
}

class _OpeningTreeWidgetState extends State<OpeningTreeWidget> {
  final TextEditingController _searchController = TextEditingController();
  List<RepertoireLine> _filteredLines = [];

  /// What the pane shows for one cursor position, derived once per
  /// (tree, FEN, lines, coverage result) rather than on every rebuild.
  ///
  /// The tree is mutable but has no version counter; the controller swaps
  /// the lines list whenever it grows the tree, so the list's identity
  /// stands in for one.  `continuations` still costs a legal-move sweep and
  /// a sort, and the pane rebuilds on every engine tick and hover.
  _PositionView? _view;

  _PositionView _viewFor(OpeningTree tree) {
    final current = _view;
    final coverageResult = widget.coverageResult;
    if (current != null &&
        identical(current.tree, tree) &&
        identical(current.lines, widget.repertoireLines) &&
        identical(current.coverage?.result, coverageResult) &&
        current.fen == tree.currentFen) {
      return current;
    }
    // The coverage index outlives the position; rebuild it only when the
    // result itself changed.
    final coverage = coverageResult == null
        ? null
        : identical(current?.coverage?.result, coverageResult)
        ? current!.coverage
        : CoverageIndex(coverageResult);
    return _view = _PositionView(
      tree: tree,
      lines: widget.repertoireLines,
      fen: tree.currentFen,
      group: tree.currentGroup,
      continuations: tree.continuations,
      coverage: coverage,
    );
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      widget.onSearchChanged?.call(_searchController.text);
      _filterLines();
    });
    _filterLines();
  }

  @override
  void didUpdateWidget(OpeningTreeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Content compare for the move sequence: a host that rebuilds for an
    // unrelated reason (an engine tick, a hover) must not re-filter and
    // re-sort every line.  The lines list is compared by identity on
    // purpose — the controller swaps it on every change.
    if (!identical(oldWidget.repertoireLines, widget.repertoireLines) ||
        !listEquals(
          oldWidget.currentMoveSequence,
          widget.currentMoveSequence,
        )) {
      _filterLines();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterLines() {
    final searchTerm = _searchController.text.toLowerCase();
    final currentMoves = widget.currentMoveSequence;

    setState(() {
      _filteredLines = widget.repertoireLines.where((line) {
        // Filter by position - line must match current position moves
        if (!_lineMatchesPosition(line, currentMoves)) {
          return false;
        }

        // Filter by search term
        if (searchTerm.isNotEmpty) {
          final lineName = line.name.toLowerCase();
          final lineTitle = _extractEventTitle(line.fullPgn).toLowerCase();
          final movesString = line.moves.join(' ').toLowerCase();

          return lineName.contains(searchTerm) ||
              lineTitle.contains(searchTerm) ||
              movesString.contains(searchTerm);
        }

        return true;
      }).toList();

      // Sort by relevance - exact position matches first
      _filteredLines.sort((a, b) {
        final aExactMatch = _isExactPositionMatch(a, currentMoves);
        final bExactMatch = _isExactPositionMatch(b, currentMoves);

        if (aExactMatch && !bExactMatch) return -1;
        if (!aExactMatch && bExactMatch) return 1;

        // Then by name alphabetically
        return a.name.compareTo(b.name);
      });
    });
  }

  bool _lineMatchesPosition(RepertoireLine line, List<String> currentMoves) =>
      pgn_utils.lineMatchesPosition(line, currentMoves);

  bool _isExactPositionMatch(RepertoireLine line, List<String> currentMoves) {
    return line.moves.length >= currentMoves.length &&
        pgn_utils.lineMatchesPosition(line, currentMoves);
  }

  String _extractEventTitle(String pgn) => pgn_utils.extractEventTitle(pgn);
  @override
  Widget build(BuildContext context) {
    final tree = widget.tree;
    final movePath = tree.currentMovePathString;
    // Transposition-aware: stats and continuations are merged across every
    // path that reaches this FEN, including one-ply transpositions into book.
    final view = _viewFor(tree);
    final position = view.group;
    final continuations = view.continuations;

    // Reach annotation: how likely the analyzed player is to end up here.
    final protagonistIsWhite = widget.protagonistIsWhite;
    final reach = protagonistIsWhite != null
        ? position.reachEstimate(protagonistIsWhite: protagonistIsWhite)
        : null;
    final protagonistToMove =
        protagonistIsWhite != null &&
        isWhiteToMove(tree.currentFen) == protagonistIsWhite;

    return Column(
      children: [
        // Header with current position
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: const Border(
              bottom: BorderSide(color: AppColors.outline, width: 1),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: widget.onPathPlySelected != null
                        ? _buildClickablePath()
                        : Text(
                            movePath,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.inkSoft,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      icon: const Icon(
                        Icons.arrow_back,
                        size: 18,
                        color: AppColors.onSurfaceSoft,
                      ),
                      padding: EdgeInsets.zero,
                      tooltip: 'Back',
                      onPressed: tree.canGoBack
                          ? () => widget.onGoBack?.call()
                          : null,
                    ),
                  ),
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      icon: const Icon(
                        Icons.arrow_forward,
                        size: 18,
                        color: AppColors.onSurfaceSoft,
                      ),
                      padding: EdgeInsets.zero,
                      tooltip: 'Forward',
                      onPressed: continuations.isNotEmpty
                          ? () => widget.onGoForward?.call()
                          : null,
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      icon: const Icon(
                        Icons.copy,
                        size: 16,
                        color: AppColors.onSurfaceSoft,
                      ),
                      padding: EdgeInsets.zero,
                      tooltip: 'Copy moves',
                      onPressed: tree.currentMovePath.isEmpty
                          ? null
                          : () {
                              unawaited(
                                Clipboard.setData(
                                  ClipboardData(
                                    text: _movetext(tree.currentMovePath),
                                  ),
                                ),
                              );
                              showAppSnackBar(context, AppMessages.movesCopied);
                            },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Stats for current position (summed across transpositions).
              // The reach annotation stays terse to keep this on one line;
              // the tooltip carries the explanation.
              _buildStatsLine(position, reach),
            ],
          ),
        ),

        // Out of book warning
        if (!tree.inBook && tree.currentMovePath.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
            color: AppColors.warningSurface,
            child: const Text(
              'Current position is out of book — transposing moves still listed',
              style: TextStyle(fontSize: 11, color: AppColors.onWarning),
            ),
          ),

        // Move list
        Expanded(
          child: continuations.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: !tree.inBook
                        ? const Text(
                            'Not in the database.\nNo move from here transposes into book.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.onSurfaceMuted),
                          )
                        : tree.currentMovePath.isEmpty
                        ? const Text(
                            'No games found.\nAnalyze a player to build the tree.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.onSurfaceMuted),
                          )
                        : _buildLeafState(),
                  ),
                )
              : ListView.builder(
                  itemCount: continuations.length,
                  itemBuilder: (context, index) {
                    final child = continuations[index];
                    // Cumulative reach after this move — only meaningful for
                    // the analyzed player's own moves (their choice extends
                    // the product; ours would leave it unchanged).
                    ReachEstimate? childReach;
                    if (reach != null &&
                        protagonistToMove &&
                        position.gamesPlayed > 0) {
                      childReach = ReachEstimate(
                        reach.probability *
                            child.gamesPlayed /
                            position.gamesPlayed,
                        reach.decisionPoints +
                            (child.gamesPlayed < position.gamesPlayed ? 1 : 0),
                      );
                    }
                    return OpeningTreeMoveRow(
                      entry: child,
                      parentGamesPlayed: position.gamesPlayed,
                      perspective: widget.wdlPerspective,
                      reachEstimate: childReach,
                      coverageStatus: view.coverage?.statusOf(child),
                      onTap: () {
                        widget.onMoveSelected?.call(child.move);
                        widget.onPositionSelected?.call(child.fen);
                      },
                      onHover: widget.onHoverMove == null
                          ? null
                          : (hovered) => widget.onHoverMove!(
                              hovered ? child.move : null,
                            ),
                    );
                  },
                ),
        ),

        // Embedded PGN search bar
        if (widget.showPgnSearch && widget.repertoireLines.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: const Border(
                top: BorderSide(color: AppColors.outline, width: 1),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.library_books,
                      size: 14,
                      color: AppColors.onSurfaceSoft,
                    ),
                    SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Search Repertoire Lines',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.inkSoft,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Type to filter lines...',
                    hintStyle: const TextStyle(
                      color: AppColors.onSurfaceMuted,
                      fontSize: 11,
                    ),
                    prefixIcon: const Icon(
                      Icons.search,
                      size: 16,
                      color: AppColors.onSurfaceMuted,
                    ),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(
                              Icons.clear,
                              size: 16,
                              color: AppColors.onSurfaceMuted,
                            ),
                            onPressed: () => _searchController.clear(),
                            padding: const EdgeInsets.all(4),
                            constraints: const BoxConstraints(
                              minWidth: 24,
                              minHeight: 24,
                            ),
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: AppColors.outline),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: AppColors.outline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: AppColors.info),
                    ),
                    filled: true,
                    fillColor: AppColors.surfaceInset,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                  style: const TextStyle(fontSize: 11),
                ),

                // PGN lines list
                if (_filteredLines.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${_filteredLines.length} matching line${_filteredLines.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _filteredLines.length,
                      itemBuilder: (context, index) {
                        final line = _filteredLines[index];
                        return _buildPgnLineItem(line, index);
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Path as PGN-style movetext, e.g. "1. e4 c5 2. Nf3 d6".
  String _movetext(List<String> moves) => buildNumberedMovetext(moves);

  /// One-line position stats, with the reach annotation appended when the
  /// protagonist's color is known and we're past the starting position.
  Widget _buildStatsLine(PositionGroup position, ReachEstimate? reach) {
    final showReach =
        reach != null &&
        widget.tree.inBook &&
        widget.tree.currentMovePath.isNotEmpty;
    // Record from the displayed point of view (see [WdlPerspective]); the
    // neutral perspective keeps a plain white-draws-black triple.
    final flip = widget.wdlPerspective == WdlPerspective.playerIsBlack;
    final rate = flip ? 100 - position.winRatePercent : position.winRatePercent;
    final record = widget.wdlPerspective == WdlPerspective.whiteBlack
        ? '${position.wins}-${position.draws}-${position.losses}'
        : '${flip ? position.losses : position.wins}W-'
              '${position.draws}D-'
              '${flip ? position.wins : position.losses}L';
    final noun = position.hasWdl ? 'games' : 'lines';
    final text = Text(
      position.hasWdl
          ? '${position.gamesPlayed} $noun • '
                '${rate.toStringAsFixed(1)}% '
                '($record)'
                '${position.nodes.length > 1 ? ' • ${position.nodes.length} move orders' : ''}'
                '${showReach ? ' • ${reach.percentLabel}% reached' : ''}'
          : '${position.gamesPlayed} $noun'
                '${position.nodes.length > 1 ? ' • ${position.nodes.length} move orders' : ''}',
      style: const TextStyle(fontSize: 11, color: AppColors.inkSoft),
    );
    if (!showReach) return text;
    return Tooltip(
      message:
          '${reach.percentLabel}% reached: chance this player plays into '
          'this position when you head down this line — the product of how '
          'often they chose each of their moves along the path '
          '(${reach.decisionPoints} branch '
          'point${reach.decisionPoints == 1 ? '' : 's'} where they sometimes '
          'play something else, highlighted in the move path above). Your '
          'own moves count as 100% — you pick those.',
      child: text,
    );
  }

  /// Move path rendered as tappable tokens: tap a move to jump to that ply,
  /// tap the leading restart icon to return to the starting position.
  Widget _buildClickablePath() {
    final moves = widget.tree.currentMovePath;
    final currentNode = widget.tree.currentNode;
    if (moves.isEmpty) {
      return const Text(
        'Starting position',
        style: TextStyle(
          fontSize: 12,
          color: AppColors.inkSoft,
          fontWeight: FontWeight.w500,
        ),
      );
    }

    final tokens = <Widget>[
      InkWell(
        onTap: () => widget.onPathPlySelected!(0),
        borderRadius: BorderRadius.circular(3),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: Icon(
            Icons.restart_alt,
            size: 14,
            color: AppColors.onSurfaceSoft,
          ),
        ),
      ),
    ];

    // Node chain aligned with the SAN list: chain[i] is the node reached by
    // moves[i], so each token can inspect its own frequency and siblings.
    final reversedChain = <OpeningTreeNode>[];
    for (
      OpeningTreeNode? n = currentNode;
      n != null && n.parent != null;
      n = n.parent
    ) {
      reversedChain.add(n);
    }
    final chain = reversedChain.reversed.toList();

    for (int i = 0; i < moves.length; i++) {
      final label = i % 2 == 0 ? '${i ~/ 2 + 1}.${moves[i]}' : moves[i];
      final isCurrent = i == moves.length - 1;
      final branchTip = i < chain.length ? _branchPointTip(chain[i]) : null;
      Widget token = InkWell(
        onTap: () => widget.onPathPlySelected!(i + 1),
        borderRadius: BorderRadius.circular(3),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          decoration: branchTip == null
              ? null
              : BoxDecoration(
                  color: AppColors.surfaceInset,
                  borderRadius: BorderRadius.circular(3),
                ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: isCurrent ? AppColors.pgnMove : AppColors.inkSoft,
              fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      );
      if (branchTip != null) {
        token = Tooltip(message: branchTip, child: token);
      }
      tokens.add(token);
    }

    // Long lines wrap; cap the height and keep the latest moves in view.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 56),
      child: SingleChildScrollView(
        reverse: true,
        child: Wrap(spacing: 2, runSpacing: 2, children: tokens),
      ),
    );
  }

  /// Tooltip for a path move that is one of the analyzed player's branch
  /// points — a move they sometimes replace with something else. Null when
  /// the move isn't theirs, they always play it, or no protagonist colour is
  /// known (repertoire/PGN-viewer trees).
  String? _branchPointTip(OpeningTreeNode node) {
    final protagonistIsWhite = widget.protagonistIsWhite;
    final parent = node.parent;
    if (protagonistIsWhite == null || parent == null) return null;
    if (node.moverWasWhite != protagonistIsWhite) return null;
    if (parent.gamesPlayed <= 0 || node.gamesPlayed >= parent.gamesPlayed) {
      return null;
    }
    final pct = (node.gamesPlayed / parent.gamesPlayed * 100).toStringAsFixed(
      0,
    );
    final siblings = parent.sortedChildren
        .where((c) => c.move != node.move)
        .map(
          (c) =>
              '${c.move} (${c.gamesPlayed} game${c.gamesPlayed == 1 ? '' : 's'})',
        )
        .join(', ');
    final alternatives = siblings.isEmpty
        ? 'their other games ended before this move.'
        : 'Elsewhere they played: $siblings.';
    return 'Branch point: this player chose ${node.move} in '
        '${node.gamesPlayed} of ${parent.gamesPlayed} games ($pct%). '
        '$alternatives Tap the move before this one to see every branch in '
        'the list below.';
  }

  Widget _buildLeafState() {
    final games = widget.gamesAtPosition;
    if (games.isEmpty || widget.onViewGamePgn == null) {
      return const Text(
        'No more moves in the tree.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.onSurfaceMuted),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'End of opening tree',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.onSurfaceSoft),
        ),
        const SizedBox(height: 12),
        if (games.length == 1) ...[
          FilledButton.tonalIcon(
            onPressed: () => widget.onViewGamePgn!(games.first),
            icon: const Icon(Icons.description_outlined, size: 18),
            label: const Text('View full game PGN'),
          ),
          const SizedBox(height: 6),
          Text(
            games.first.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.onSurfaceMuted,
            ),
          ),
        ] else ...[
          Text(
            '${games.length} games reach this position',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.onSurfaceMuted,
            ),
          ),
          const SizedBox(height: 8),
          ...games
              .take(5)
              .map(
                (game) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => widget.onViewGamePgn!(game),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        alignment: Alignment.centerLeft,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            game.title,
                            style: const TextStyle(fontSize: 12),
                          ),
                          if (game.date.isNotEmpty ||
                              game.eloDisplay.isNotEmpty)
                            Text(
                              [
                                game.date,
                                game.eloDisplay,
                              ].where((s) => s.isNotEmpty).join(' · '),
                              style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.onSurfaceMuted,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ],
    );
  }

  Widget _buildPgnLineItem(RepertoireLine line, int index) {
    final title = _extractEventTitle(line.fullPgn);
    final displayTitle = title.isNotEmpty ? title : line.name;
    final isEven = index % 2 == 0;

    return InkWell(
      onTap: () => widget.onLineSelected?.call(line),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isEven ? AppColors.surfaceInset : AppColors.chipInactiveBg,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.outline, width: 0.5),
        ),
        margin: const EdgeInsets.symmetric(vertical: 1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            Text(
              displayTitle,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),

            // First few moves and move count
            Row(
              children: [
                Expanded(
                  child: Text(
                    line.moves.take(4).join(' '),
                    style: const TextStyle(
                      color: AppColors.onSurfaceSoft,
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${line.moves.length}m',
                  style: const TextStyle(
                    color: AppColors.onSurfaceMuted,
                    fontSize: 9,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One cursor position's view of the tree: the merged group, its
/// continuations, and the coverage index that classifies them.  See
/// `_OpeningTreeWidgetState._viewFor` for when it is rebuilt.
class _PositionView {
  const _PositionView({
    required this.tree,
    required this.lines,
    required this.fen,
    required this.group,
    required this.continuations,
    required this.coverage,
  });

  final OpeningTree tree;
  final List<RepertoireLine> lines;
  final String fen;
  final PositionGroup group;
  final List<PositionGroup> continuations;
  final CoverageIndex? coverage;
}
