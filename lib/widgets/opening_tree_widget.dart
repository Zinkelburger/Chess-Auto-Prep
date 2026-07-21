/// Opening tree widget - Interactive move tree explorer
/// Similar to openingtree.com's interface
library;

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
  });

  @override
  State<OpeningTreeWidget> createState() => _OpeningTreeWidgetState();
}

class _OpeningTreeWidgetState extends State<OpeningTreeWidget> {
  final TextEditingController _searchController = TextEditingController();
  List<RepertoireLine> _filteredLines = [];

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
    if (oldWidget.repertoireLines != widget.repertoireLines ||
        oldWidget.currentMoveSequence != widget.currentMoveSequence) {
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
    final currentNode = widget.tree.currentNode;
    final movePath = currentNode.getMovePathString();
    // Transposition-aware: stats and continuations are merged across every
    // path that reaches this position, so counts match the FEN list.
    final position = widget.tree.groupFor(currentNode);
    final continuations = position.children;

    // Reach annotation: how likely the analyzed player is to end up here.
    final protagonistIsWhite = widget.protagonistIsWhite;
    final reach = protagonistIsWhite != null
        ? position.reachEstimate(protagonistIsWhite: protagonistIsWhite)
        : null;
    final fenParts = currentNode.fen.split(' ');
    final protagonistToMove =
        protagonistIsWhite != null &&
        fenParts.length > 1 &&
        (fenParts[1] == 'w') == protagonistIsWhite;

    return Column(
      children: [
        // Header with current position
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border(
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
                        ? _buildClickablePath(currentNode)
                        : Text(
                            movePath,
                            style: TextStyle(
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
                      icon: Icon(
                        Icons.arrow_back,
                        size: 18,
                        color: AppColors.onSurfaceSoft,
                      ),
                      padding: EdgeInsets.zero,
                      tooltip: 'Back',
                      onPressed: currentNode.parent != null
                          ? () => widget.onGoBack?.call()
                          : null,
                    ),
                  ),
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      icon: Icon(
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
                      icon: Icon(
                        Icons.copy,
                        size: 16,
                        color: AppColors.onSurfaceSoft,
                      ),
                      padding: EdgeInsets.zero,
                      tooltip: 'Copy FEN',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: currentNode.fen));
                        showAppSnackBar(context, AppMessages.fenCopied);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Stats for current position (summed across transpositions).
              // The reach annotation stays terse to keep this on one line;
              // the tooltip carries the explanation.
              _buildStatsLine(position, reach, currentNode),
            ],
          ),
        ),

        // Out of book warning
        if (widget.currentMoveSequence.length > widget.tree.currentDepth)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
            color: AppColors.warningSurface,
            child: const Text(
              'Current position is out of book',
              style: TextStyle(fontSize: 11, color: AppColors.onWarning),
            ),
          ),

        // Move list
        Expanded(
          child: continuations.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: currentNode.parent == null
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
                      coverageStatus: resolveCoverageStatus(
                        group: child,
                        tree: widget.tree,
                        coverageResult: widget.coverageResult,
                      ),
                      onTap: () {
                        widget.onMoveSelected?.call(child.move);
                        widget.onPositionSelected?.call(child.fen);
                      },
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
              border: Border(
                top: BorderSide(color: AppColors.outline, width: 1),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.library_books,
                      size: 14,
                      color: AppColors.onSurfaceSoft,
                    ),
                    const SizedBox(width: 6),
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
                    hintStyle: TextStyle(
                      color: AppColors.onSurfaceMuted,
                      fontSize: 11,
                    ),
                    prefixIcon: Icon(
                      Icons.search,
                      size: 16,
                      color: AppColors.onSurfaceMuted,
                    ),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: Icon(
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
                    style: TextStyle(
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

  /// One-line position stats, with the reach annotation appended when the
  /// protagonist's color is known and we're past the starting position.
  Widget _buildStatsLine(
    PositionGroup position,
    ReachEstimate? reach,
    OpeningTreeNode currentNode,
  ) {
    final showReach = reach != null && currentNode.parent != null;
    final text = Text(
      '${position.gamesPlayed} games • '
      '${position.winRatePercent.toStringAsFixed(1)}% '
      '(${position.wins}-${position.losses}-${position.draws})'
      '${position.nodes.length > 1 ? ' • ${position.nodes.length} move orders' : ''}'
      '${showReach ? ' • ${reach.percentLabel}% reached' : ''}',
      style: TextStyle(fontSize: 11, color: AppColors.inkSoft),
    );
    if (!showReach) return text;
    return Tooltip(
      message:
          '${reach.percentLabel}% reached: chance this player plays into '
          'this position when you head down this line — the product of how '
          'often they chose each of their moves along the path '
          '(${reach.decisionPoints} branch '
          'point${reach.decisionPoints == 1 ? '' : 's'} where they sometimes '
          'play something else). Your own moves count as 100% — you pick '
          'those.',
      child: text,
    );
  }

  /// Move path rendered as tappable tokens: tap a move to jump to that ply,
  /// tap the leading restart icon to return to the starting position.
  Widget _buildClickablePath(OpeningTreeNode currentNode) {
    final moves = currentNode.getMovePath();
    if (moves.isEmpty) {
      return Text(
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: Icon(
            Icons.restart_alt,
            size: 14,
            color: AppColors.onSurfaceSoft,
          ),
        ),
      ),
    ];

    for (int i = 0; i < moves.length; i++) {
      final label = i % 2 == 0 ? '${i ~/ 2 + 1}.${moves[i]}' : moves[i];
      final isCurrent = i == moves.length - 1;
      tokens.add(
        InkWell(
          onTap: () => widget.onPathPlySelected!(i + 1),
          borderRadius: BorderRadius.circular(3),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: isCurrent ? AppColors.pgnMove : AppColors.inkSoft,
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      );
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
        Text(
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
            style: TextStyle(fontSize: 11, color: AppColors.onSurfaceMuted),
          ),
        ] else ...[
          Text(
            '${games.length} games reach this position',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
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
                              style: TextStyle(
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
                    style: TextStyle(
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
                  style: TextStyle(
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
