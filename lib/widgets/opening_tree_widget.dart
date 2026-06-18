/// Opening tree widget - Interactive move tree explorer
/// Similar to openingtree.com's interface
library;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'package:flutter/services.dart';
import '../models/opening_tree.dart';
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
            color: AppColors.warningSurface,
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
                    return OpeningTreeMoveRow(
                      node: child,
                      parentGamesPlayed: currentNode.gamesPlayed,
                      coverageStatus: resolveCoverageStatus(
                        node: child,
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
}
