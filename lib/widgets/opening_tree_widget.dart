/// Opening tree widget - Interactive move tree explorer
/// Similar to openingtree.com's interface

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/opening_tree.dart';
import '../models/repertoire_line.dart';
import '../services/coverage_service.dart';
import '../utils/app_messages.dart';
import '../utils/fen_utils.dart';
import '../utils/pgn_utils.dart' as pgn_utils;

enum _CoverageStatus { covered, tooShallow, tooDeep, unaccounted }

class OpeningTreeWidget extends StatefulWidget {
  final OpeningTree tree;
  final Function(String fen)? onPositionSelected;
  final Function(String move)? onMoveSelected;
  final Function(String searchTerm)? onSearchChanged;
  final Function(RepertoireLine line)? onLineSelected;
  final VoidCallback? onGoBack;
  final VoidCallback? onGoForward;
  final List<RepertoireLine> repertoireLines;
  final List<String> currentMoveSequence;
  final bool showPgnSearch;
  final CoverageResult? coverageResult;

  const OpeningTreeWidget({
    super.key,
    required this.tree,
    this.onPositionSelected,
    this.onMoveSelected,
    this.onSearchChanged,
    this.onLineSelected,
    this.onGoBack,
    this.onGoForward,
    this.repertoireLines = const [],
    this.currentMoveSequence = const [],
    this.showPgnSearch = false,
    this.coverageResult,
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
    final sortedChildren = currentNode.sortedChildren;

    return Column(
      children: [
        // Header with current position
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border(
              bottom: BorderSide(
                color: Colors.grey[700]!,
                width: 1,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      movePath,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[300],
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
                      icon: Icon(Icons.arrow_back,
                          size: 18, color: Colors.grey[400]),
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
                      icon: Icon(Icons.arrow_forward,
                          size: 18, color: Colors.grey[400]),
                      padding: EdgeInsets.zero,
                      tooltip: 'Forward',
                      onPressed: sortedChildren.isNotEmpty
                          ? () => widget.onGoForward?.call()
                          : null,
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      icon: Icon(Icons.copy, size: 16, color: Colors.grey[400]),
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
              // Stats for current position
              Text(
                '${currentNode.gamesPlayed} games • '
                '${currentNode.winRatePercent.toStringAsFixed(1)}% '
                '(${currentNode.wins}-${currentNode.losses}-${currentNode.draws})',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[300],
                ),
              ),
            ],
          ),
        ),

        // Out of book warning
        if (widget.currentMoveSequence.length > widget.tree.currentDepth)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
            color: Colors.orange[900],
            child: const Text(
              'Current position is out of book',
              style: TextStyle(fontSize: 11, color: Colors.white),
            ),
          ),

        // Move list
        Expanded(
          child: sortedChildren.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      currentNode.parent == null
                          ? 'No games found.\nAnalyze a player to build the tree.'
                          : 'No more moves in the database.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: sortedChildren.length,
                  itemBuilder: (context, index) {
                    final child = sortedChildren[index];
                    return _buildMoveItem(child);
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
                top: BorderSide(
                  color: Colors.grey[700]!,
                  width: 1,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.library_books,
                        size: 14, color: Colors.grey[400]),
                    const SizedBox(width: 6),
                    Text(
                      'Search Repertoire Lines',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[300],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Type to filter lines...',
                    hintStyle: TextStyle(color: Colors.grey[500], fontSize: 11),
                    prefixIcon:
                        Icon(Icons.search, size: 16, color: Colors.grey[500]),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.clear,
                                size: 16, color: Colors.grey[500]),
                            onPressed: () => _searchController.clear(),
                            padding: const EdgeInsets.all(4),
                            constraints: const BoxConstraints(
                                minWidth: 24, minHeight: 24),
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: Colors.grey[700]!),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: Colors.grey[700]!),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: Colors.blue[400]!),
                    ),
                    filled: true,
                    fillColor: Colors.grey[850],
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
                      color: Colors.grey[500],
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

  Widget _buildPgnLineItem(RepertoireLine line, int index) {
    final title = _extractEventTitle(line.fullPgn);
    final displayTitle = title.isNotEmpty ? title : line.name;
    final isEven = index % 2 == 0;

    return InkWell(
      onTap: () => widget.onLineSelected?.call(line),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isEven ? Colors.grey[850] : Colors.grey[800],
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.grey[700]!, width: 0.5),
        ),
        margin: const EdgeInsets.symmetric(vertical: 1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            Text(
              displayTitle,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 11,
              ),
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
                      color: Colors.grey[400],
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
                    color: Colors.grey[500],
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

  /// Determine coverage status for a child node based on its FEN.
  _CoverageStatus? _coverageStatusForNode(OpeningTreeNode node) {
    final result = widget.coverageResult;
    if (result == null) return null;

    final normalized = normalizeFen(node.fen);

    // Check if any leaf matches this node's FEN
    for (final leaf in result.tooShallowLeaves) {
      if (_leafMatchesFen(leaf, normalized)) {
        return _CoverageStatus.tooShallow;
      }
    }
    for (final leaf in result.tooDeepLeaves) {
      if (_leafMatchesFen(leaf, normalized)) {
        return _CoverageStatus.tooDeep;
      }
    }

    // Check for unaccounted moves at this position
    for (final um in result.unaccountedMoves) {
      // The parent of the unaccounted move leads to this node
      if (_unaccountedAtFen(um, normalized)) {
        return _CoverageStatus.unaccounted;
      }
    }

    for (final leaf in result.coveredLeaves) {
      if (_leafMatchesFen(leaf, normalized)) {
        return _CoverageStatus.covered;
      }
    }

    return null;
  }

  bool _leafMatchesFen(LeafNode leaf, String normalizedFen) {
    return normalizeFen(leaf.fen) == normalizedFen;
  }

  bool _unaccountedAtFen(UnaccountedMove um, String normalizedFen) {
    // Rebuild the FEN for parentMoves + move (the destination position)
    // But that's expensive. Instead check if the node's FEN is the parent position.
    // We can't easily rebuild here, so we use a simpler heuristic:
    // match via the tree's fen-to-node index.
    return false; // Handled at the parent level below.
  }

  /// Check if there are unaccounted moves FROM this position (opponent responses
  /// that our repertoire doesn't cover).
  bool _hasUnaccountedFrom(OpeningTreeNode node) {
    final result = widget.coverageResult;
    if (result == null) return false;
    final normalized = normalizeFen(node.fen);

    // Check all positions in the tree that match this FEN
    for (final um in result.unaccountedMoves) {
      // Rebuild parent fen would be expensive; instead use allLeaves + tree
      // The unaccounted parent position can be found via the tree's fenToNodes
      final parentNodes = widget.tree.fenToNodes[normalized];
      if (parentNodes != null && parentNodes.isNotEmpty) {
        // Check if this node has child moves that don't include the unaccounted move
        final repertoireMoves = node.children.keys.toSet();
        if (!repertoireMoves.contains(um.move)) {
          // Verify the unaccounted move's parent path matches
          final nodePath = node.getMovePath();
          if (_pathMatchesUnaccounted(nodePath, um.parentMoves)) {
            return true;
          }
        }
      }
    }
    return false;
  }

  bool _pathMatchesUnaccounted(
      List<String> nodePath, List<String> parentMoves) {
    if (nodePath.length != parentMoves.length) return false;
    for (int i = 0; i < nodePath.length; i++) {
      if (nodePath[i] != parentMoves[i]) return false;
    }
    return true;
  }

  Widget _buildCoverageIndicator(_CoverageStatus status) {
    Color color;
    switch (status) {
      case _CoverageStatus.covered:
        color = const Color(0xFF4CAF50);
      case _CoverageStatus.tooShallow:
        color = const Color(0xFFFFA726);
      case _CoverageStatus.tooDeep:
        color = const Color(0xFF42A5F5);
      case _CoverageStatus.unaccounted:
        color = const Color(0xFFEF5350);
    }

    return Container(
      width: 8,
      height: 8,
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Widget _buildMoveItem(OpeningTreeNode node) {
    final totalGames = widget.tree.currentNode.gamesPlayed;
    final playedPercent =
        totalGames > 0 ? (node.gamesPlayed / totalGames * 100) : 0.0;

    // Color based on win rate
    Color winRateColor;
    if (node.winRate >= 0.55) {
      winRateColor = Colors.green;
    } else if (node.winRate >= 0.45) {
      winRateColor = Colors.orange;
    } else {
      winRateColor = Colors.red;
    }

    // Coverage indicator
    _CoverageStatus? covStatus = _coverageStatusForNode(node);
    if (covStatus == null && _hasUnaccountedFrom(node)) {
      covStatus = _CoverageStatus.unaccounted;
    }

    return InkWell(
      onTap: () {
        widget.onMoveSelected?.call(node.move);
        widget.onPositionSelected?.call(node.fen);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Colors.grey[800]!,
              width: 0.5,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Move and stats row
            Row(
              children: [
                if (covStatus != null) _buildCoverageIndicator(covStatus),
                // Move notation
                SizedBox(
                  width: 60,
                  child: Text(
                    node.move,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Games played
                Expanded(
                  child: Text(
                    '${node.gamesPlayed} games (${playedPercent.toStringAsFixed(1)}%)',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[400],
                    ),
                  ),
                ),

                // Win rate
                Text(
                  '${node.winRatePercent.toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: winRateColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Visual stats bar
            Row(
              children: [
                // W-D-L text
                SizedBox(
                  width: 100,
                  child: Text(
                    '${node.wins}-${node.draws}-${node.losses}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[500],
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Win rate bar
                Expanded(
                  child: _buildWinRateBar(node),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Build a visual win rate bar similar to openingtree.com
  Widget _buildWinRateBar(OpeningTreeNode node) {
    final winPercent =
        node.gamesPlayed > 0 ? node.wins / node.gamesPlayed : 0.0;
    final drawPercent =
        node.gamesPlayed > 0 ? node.draws / node.gamesPlayed : 0.0;
    final lossPercent =
        node.gamesPlayed > 0 ? node.losses / node.gamesPlayed : 0.0;

    return Container(
      height: 16,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: Colors.grey[700]!, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(1),
        child: Row(
          children: [
            // Win section (green)
            if (winPercent > 0)
              Expanded(
                flex: (winPercent * 100).round(),
                child: Container(
                  color: Colors.green[600],
                ),
              ),
            // Draw section (grey)
            if (drawPercent > 0)
              Expanded(
                flex: (drawPercent * 100).round(),
                child: Container(
                  color: Colors.grey[600],
                ),
              ),
            // Loss section (red)
            if (lossPercent > 0)
              Expanded(
                flex: (lossPercent * 100).round(),
                child: Container(
                  color: Colors.red[600],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
