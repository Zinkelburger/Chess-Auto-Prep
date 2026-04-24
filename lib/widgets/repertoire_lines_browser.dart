/// Repertoire Lines Browser Widget
/// A comprehensive view of all lines in a repertoire with filtering,
/// grouping, detailed previews, and optional coverage annotations
library;

import 'package:flutter/material.dart';
import '../models/repertoire_line.dart';
import '../services/coverage_service.dart';
import '../utils/pgn_utils.dart' as pgn_utils;

/// Groups lines by their opening structure for better organization
class LineGroup {
  final String name;
  final String prefix;
  final List<RepertoireLine> lines;

  LineGroup({
    required this.name,
    required this.prefix,
    required this.lines,
  });

  int get totalMoves => lines.fold(0, (sum, line) => sum + line.moves.length);
}

/// Coverage category filter for the lines browser
enum CoverageFilter {
  all,
  covered,
  tooShallow,
  tooDeep,
  unaccounted,
}

class RepertoireLinesBrowser extends StatefulWidget {
  final List<RepertoireLine> lines;
  final List<String> currentMoveSequence;
  final Function(RepertoireLine line)? onLineSelected;
  final Function(RepertoireLine line, String newTitle)? onLineRenamed;
  final VoidCallback? onCoveragePressed;
  final bool isCoverageRunning;
  final bool isExpanded;
  final CoverageResult? coverageResult;

  const RepertoireLinesBrowser({
    super.key,
    required this.lines,
    this.currentMoveSequence = const [],
    this.onLineSelected,
    this.onLineRenamed,
    this.onCoveragePressed,
    this.isCoverageRunning = false,
    this.isExpanded = false,
    this.coverageResult,
  });

  @override
  State<RepertoireLinesBrowser> createState() => _RepertoireLinesBrowserState();
}

class _RepertoireLinesBrowserState extends State<RepertoireLinesBrowser> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<RepertoireLine> _filteredLines = [];
  Map<String, List<RepertoireLine>> _groupedLines = {};
  final Set<String> _expandedGroups = {};

  bool _showOnlyMatchingPosition = true;
  String _sortBy = 'name';
  CoverageFilter _coverageFilter = CoverageFilter.all;

  /// Pre-computed coverage info per line (keyed by line id)
  Map<String, _LineCoverageInfo> _lineCoverage = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _computeLineCoverage();
    _filterAndGroupLines();
  }

  @override
  void didUpdateWidget(RepertoireLinesBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverageResult != widget.coverageResult) {
      _computeLineCoverage();
    }
    if (oldWidget.lines != widget.lines ||
        oldWidget.currentMoveSequence != widget.currentMoveSequence ||
        oldWidget.coverageResult != widget.coverageResult) {
      _filterAndGroupLines();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _filterAndGroupLines();
  }

  // ── Coverage matching ──────────────────────────────────────────────────

  void _computeLineCoverage() {
    _lineCoverage = {};
    final result = widget.coverageResult;
    if (result == null) return;

    for (final line in widget.lines) {
      final info = _matchLineToCoverage(line, result);
      _lineCoverage[line.id] = info;
    }
  }

  /// Match a repertoire line to coverage leaves and unaccounted moves.
  /// A line matches a leaf if the leaf's move sequence is the line's moves
  /// (or starts with the same prefix for the line within the tree context).
  _LineCoverageInfo _matchLineToCoverage(
      RepertoireLine line, CoverageResult result) {
    final lineMoves = line.moves;

    // Find the best matching leaf (longest common prefix)
    LeafNode? bestLeaf;
    int bestMatch = 0;

    for (final leaf in result.allLeaves) {
      final depth = _commonPrefixLength(lineMoves, leaf.moves);
      if (depth > bestMatch) {
        bestMatch = depth;
        bestLeaf = leaf;
      }
    }

    // Collect unaccounted moves along this line
    final unaccounted = <UnaccountedMove>[];
    for (final um in result.unaccountedMoves) {
      // The unaccounted move's parentMoves should be a prefix of our line
      if (_isPrefix(um.parentMoves, lineMoves)) {
        unaccounted.add(um);
      }
    }

    // Group unaccounted by position (parentMoves key)
    final groupedUnaccounted = <String, List<UnaccountedMove>>{};
    for (final um in unaccounted) {
      final key = um.parentMoves.join(' ');
      groupedUnaccounted.putIfAbsent(key, () => []).add(um);
    }

    return _LineCoverageInfo(
      leaf: bestLeaf,
      unaccountedMoves: unaccounted,
      groupedUnaccounted: groupedUnaccounted,
    );
  }

  int _commonPrefixLength(List<String> a, List<String> b) {
    int i = 0;
    while (i < a.length && i < b.length && a[i] == b[i]) {
      i++;
    }
    return i;
  }

  bool _isPrefix(List<String> prefix, List<String> list) {
    if (prefix.length > list.length) return false;
    for (int i = 0; i < prefix.length; i++) {
      if (prefix[i] != list[i]) return false;
    }
    return true;
  }

  // ── Filtering & grouping ───────────────────────────────────────────────

  void _filterAndGroupLines() {
    final searchTerm = _searchController.text.toLowerCase().trim();
    final currentMoves = widget.currentMoveSequence;

    var filtered = widget.lines.where((line) {
      if (_showOnlyMatchingPosition && currentMoves.isNotEmpty) {
        if (!_lineMatchesPosition(line, currentMoves)) {
          return false;
        }
      }

      if (searchTerm.isNotEmpty) {
        final lineName = line.name.toLowerCase();
        final eventTitle = _extractEventTitle(line.fullPgn).toLowerCase();
        final movesString = line.moves.join(' ').toLowerCase();
        final formattedMoves = _formatMovesForSearch(line.moves).toLowerCase();

        if (!lineName.contains(searchTerm) &&
            !eventTitle.contains(searchTerm) &&
            !movesString.contains(searchTerm) &&
            !formattedMoves.contains(searchTerm)) {
          return false;
        }
      }

      // Coverage filter — leaf category and unaccounted are orthogonal.
      // Covered/shallow/deep filter by leaf; unaccounted filters by
      // whether there are missing opponent moves along the line.
      if (_coverageFilter != CoverageFilter.all &&
          widget.coverageResult != null) {
        final info = _lineCoverage[line.id];
        if (info == null) return false;

        switch (_coverageFilter) {
          case CoverageFilter.covered:
            return info.leaf?.category == LeafCategory.covered;
          case CoverageFilter.tooShallow:
            return info.leaf?.category == LeafCategory.tooShallow;
          case CoverageFilter.tooDeep:
            return info.leaf?.category == LeafCategory.tooDeep;
          case CoverageFilter.unaccounted:
            return info.unaccountedMoves.isNotEmpty;
          case CoverageFilter.all:
            return true;
        }
      }

      return true;
    }).toList();

    switch (_sortBy) {
      case 'length':
        filtered.sort((a, b) => b.moves.length.compareTo(a.moves.length));
        break;
      case 'position':
        filtered.sort((a, b) {
          final aMatch = _getPositionMatchDepth(a, currentMoves);
          final bMatch = _getPositionMatchDepth(b, currentMoves);
          if (aMatch != bMatch) return bMatch.compareTo(aMatch);
          return a.name.compareTo(b.name);
        });
        break;
      case 'name':
      default:
        filtered.sort((a, b) => a.name.compareTo(b.name));
    }

    final grouped = <String, List<RepertoireLine>>{};
    for (final line in filtered) {
      final groupName = _getGroupName(line);
      grouped.putIfAbsent(groupName, () => []).add(line);
    }

    setState(() {
      _filteredLines = filtered;
      _groupedLines = grouped;

      if (currentMoves.isNotEmpty) {
        for (final entry in grouped.entries) {
          final hasExactMatch = entry.value.any((l) =>
              l.moves.length >= currentMoves.length &&
              _lineMatchesPosition(l, currentMoves));
          if (hasExactMatch) {
            _expandedGroups.add(entry.key);
          }
        }
      }
    });
  }

  bool _lineMatchesPosition(RepertoireLine line, List<String> currentMoves) =>
      pgn_utils.lineMatchesPosition(line, currentMoves);

  int _getPositionMatchDepth(RepertoireLine line, List<String> currentMoves) =>
      pgn_utils.getPositionMatchDepth(line, currentMoves);

  bool _isPlaceholderTitle(String title) =>
      title.isEmpty ||
      title == '?' ||
      title == 'Repertoire Line' ||
      title == 'Edited Line';

  String _getGroupName(RepertoireLine line) {
    final eventTitle = _extractEventTitle(line.fullPgn);
    if (!_isPlaceholderTitle(eventTitle)) {
      final parts = eventTitle.split(RegExp(r'[:\-–#]'));
      if (parts.isNotEmpty) {
        return parts[0].trim();
      }
      return eventTitle;
    }

    if (line.moves.length >= 2) {
      return '1.${line.moves[0]} ${line.moves[1]}';
    } else if (line.moves.isNotEmpty) {
      return '1.${line.moves[0]}';
    }
    return 'Other';
  }

  String _extractEventTitle(String pgn) => pgn_utils.extractEventTitle(pgn);

  String _formatMovesForSearch(List<String> moves) =>
      pgn_utils.formatMovesForSearch(moves);

  // ── Coverage counts for filter chips ───────────────────────────────────

  int get _coveredCount => _lineCoverage.values
      .where((i) => i.leaf?.category == LeafCategory.covered)
      .length;
  int get _shallowCount => _lineCoverage.values
      .where((i) => i.leaf?.category == LeafCategory.tooShallow)
      .length;
  int get _deepCount => _lineCoverage.values
      .where((i) => i.leaf?.category == LeafCategory.tooDeep)
      .length;
  int get _unaccountedCount =>
      _lineCoverage.values.where((i) => i.unaccountedMoves.isNotEmpty).length;
  int get _totalUnaccountedMoves => _lineCoverage.values
      .fold(0, (sum, i) => sum + i.unaccountedMoves.length);

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildHeader(),
        if (widget.coverageResult != null) _buildCoverageSummaryBar(),
        if (widget.coverageResult != null) _buildCoverageFilters(),
        _buildStatsBar(),
        Expanded(
          child:
              _filteredLines.isEmpty ? _buildEmptyState() : _buildLinesList(),
        ),
      ],
    );
  }

  // ── Coverage summary bar ───────────────────────────────────────────────

  Widget _buildCoverageSummaryBar() {
    final total = _lineCoverage.length;
    if (total == 0) return const SizedBox.shrink();

    double pct(int count) => (count / total) * 100;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        border: Border(
          bottom: BorderSide(color: Colors.grey[800]!, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          _buildCoverageStat(
              'Covered', pct(_coveredCount), const Color(0xFF4CAF50)),
          const SizedBox(width: 4),
          Text('|', style: TextStyle(fontSize: 10, color: Colors.grey[600])),
          const SizedBox(width: 4),
          _buildCoverageStat(
              'Shallow', pct(_shallowCount), const Color(0xFFFFA726)),
          const SizedBox(width: 4),
          Text('|', style: TextStyle(fontSize: 10, color: Colors.grey[600])),
          const SizedBox(width: 4),
          _buildCoverageStat(
              'Deep', pct(_deepCount), const Color(0xFF42A5F5)),
          if (_totalUnaccountedMoves > 0) ...[
            const Spacer(),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFFEF5350),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '$_totalUnaccountedMoves unaccounted move${_totalUnaccountedMoves == 1 ? '' : 's'}',
                  style: TextStyle(fontSize: 10, color: Colors.grey[300]),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCoverageStat(String label, double percent, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          '$label: ${percent.toStringAsFixed(1)}%',
          style: TextStyle(fontSize: 10, color: Colors.grey[300]),
        ),
      ],
    );
  }

  // ── Coverage filter chips ──────────────────────────────────────────────

  Widget _buildCoverageFilters() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        border: Border(
          bottom: BorderSide(color: Colors.grey[800]!, width: 0.5),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildCoverageChip(
                'All', CoverageFilter.all, null, widget.lines.length),
            const SizedBox(width: 6),
            _buildCoverageChip('Covered', CoverageFilter.covered,
                const Color(0xFF4CAF50), _coveredCount),
            const SizedBox(width: 6),
            _buildCoverageChip('Too Shallow', CoverageFilter.tooShallow,
                const Color(0xFFFFA726), _shallowCount),
            const SizedBox(width: 6),
            _buildCoverageChip('Too Deep', CoverageFilter.tooDeep,
                const Color(0xFF42A5F5), _deepCount),
            const SizedBox(width: 6),
            _buildCoverageChip('Unaccounted', CoverageFilter.unaccounted,
                const Color(0xFFEF5350), _unaccountedCount),
          ],
        ),
      ),
    );
  }

  Widget _buildCoverageChip(
      String label, CoverageFilter filter, Color? color, int count) {
    final isSelected = _coverageFilter == filter;
    return GestureDetector(
      onTap: () {
        setState(() => _coverageFilter = filter);
        _filterAndGroupLines();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? (color ?? Colors.blue[700]) : Colors.grey[800],
          borderRadius: BorderRadius.circular(12),
          border: color != null && !isSelected
              ? Border.all(color: color.withValues(alpha: 0.4), width: 1)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? Colors.white : Colors.grey[400],
              ),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: isSelected
                    ? Colors.white.withValues(alpha: 0.25)
                    : Colors.grey[700],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? Colors.white : Colors.grey[400],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: Colors.grey[700]!, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.library_books, size: 20, color: Colors.grey[400]),
              const SizedBox(width: 8),
              Text(
                'Repertoire Lines',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[200],
                ),
              ),
              const Spacer(),
              if (widget.onCoveragePressed != null) ...[
                FilledButton.icon(
                  onPressed: widget.isCoverageRunning
                      ? null
                      : widget.onCoveragePressed,
                  icon: widget.isCoverageRunning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.analytics_outlined, size: 16),
                  label: Text(
                    widget.isCoverageRunning ? 'Analyzing...' : 'Coverage',
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              FilterChip(
                label: const Text('Current Position'),
                selected: _showOnlyMatchingPosition,
                onSelected: (value) {
                  setState(() {
                    _showOnlyMatchingPosition = value;
                  });
                  _filterAndGroupLines();
                },
                labelStyle: const TextStyle(fontSize: 11),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText:
                  'Search by name, moves (e.g., "1.e4 e5" or "Sicilian")...',
              hintStyle: TextStyle(color: Colors.grey[500], fontSize: 12),
              prefixIcon: Icon(Icons.search, size: 18, color: Colors.grey[500]),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon:
                          Icon(Icons.clear, size: 18, color: Colors.grey[500]),
                      onPressed: () {
                        _searchController.clear();
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.grey[700]!),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.grey[700]!),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.blue[400]!),
              ),
              filled: true,
              fillColor: Colors.grey[850],
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('Sort: ',
                  style: TextStyle(fontSize: 11, color: Colors.grey[400])),
              _buildSortChip('Name', 'name'),
              const SizedBox(width: 4),
              _buildSortChip('Length', 'length'),
              const SizedBox(width: 4),
              _buildSortChip('Position', 'position'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSortChip(String label, String value) {
    final isSelected = _sortBy == value;
    return GestureDetector(
      onTap: () {
        setState(() => _sortBy = value);
        _filterAndGroupLines();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue[700] : Colors.grey[800],
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? Colors.white : Colors.grey[400],
          ),
        ),
      ),
    );
  }

  Widget _buildStatsBar() {
    final currentMoves = widget.currentMoveSequence;
    final matchingCount = _filteredLines
        .where((l) => _lineMatchesPosition(l, currentMoves))
        .length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Colors.grey[900],
      child: Row(
        children: [
          Text(
            '${_filteredLines.length} line${_filteredLines.length == 1 ? '' : 's'}',
            style: TextStyle(fontSize: 11, color: Colors.grey[400]),
          ),
          if (currentMoves.isNotEmpty) ...[
            Text(' • ', style: TextStyle(color: Colors.grey[600])),
            Text(
              '$matchingCount at current position',
              style: TextStyle(fontSize: 11, color: Colors.blue[300]),
            ),
          ],
          if (_groupedLines.length > 1) ...[
            Text(' • ', style: TextStyle(color: Colors.grey[600])),
            Text(
              '${_groupedLines.length} groups',
              style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 48, color: Colors.grey[600]),
            const SizedBox(height: 16),
            Text(
              _searchController.text.isNotEmpty
                  ? 'No lines match your search'
                  : _showOnlyMatchingPosition
                      ? 'No lines match the current position'
                      : _coverageFilter != CoverageFilter.all
                          ? 'No lines in this category'
                          : 'No lines in repertoire',
              style: TextStyle(color: Colors.grey[500]),
              textAlign: TextAlign.center,
            ),
            if (_showOnlyMatchingPosition &&
                widget.currentMoveSequence.isNotEmpty) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  setState(() => _showOnlyMatchingPosition = false);
                  _filterAndGroupLines();
                },
                child: const Text('Show all lines'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLinesList() {
    if (_groupedLines.length <= 1) {
      return ListView.builder(
        controller: _scrollController,
        itemCount: _filteredLines.length,
        itemBuilder: (context, index) {
          return _buildLineItem(_filteredLines[index], index);
        },
      );
    }

    final groupKeys = _groupedLines.keys.toList();

    return ListView.builder(
      controller: _scrollController,
      itemCount: groupKeys.length,
      itemBuilder: (context, index) {
        final groupName = groupKeys[index];
        final lines = _groupedLines[groupName]!;
        final isExpanded = _expandedGroups.contains(groupName);

        return _buildGroupSection(groupName, lines, isExpanded);
      },
    );
  }

  Widget _buildGroupSection(
      String groupName, List<RepertoireLine> lines, bool isExpanded) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              if (isExpanded) {
                _expandedGroups.remove(groupName);
              } else {
                _expandedGroups.add(groupName);
              }
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              border: Border(
                bottom: BorderSide(color: Colors.grey[800]!, width: 1),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isExpanded ? Icons.expand_more : Icons.chevron_right,
                  size: 18,
                  color: Colors.grey[400],
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    groupName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.grey[700],
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${lines.length}',
                    style: TextStyle(fontSize: 11, color: Colors.grey[300]),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (isExpanded)
          ...lines.asMap().entries.map((entry) =>
              _buildLineItem(entry.value, entry.key, indented: true)),
      ],
    );
  }

  void _showRenameDialog(RepertoireLine line) {
    final eventTitle = _extractEventTitle(line.fullPgn);
    final currentTitle = !_isPlaceholderTitle(eventTitle) ? eventTitle : '';
    final controller = TextEditingController(text: currentTitle);

    final renameDialog = showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Line'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g., KID - Fianchetto Variation',
            labelText: 'Line Title',
          ),
          onSubmitted: (value) {
            final title = value.trim();
            if (title.isNotEmpty) {
              widget.onLineRenamed?.call(line, title);
            }
            Navigator.of(context).pop();
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final title = controller.text.trim();
              if (title.isNotEmpty) {
                widget.onLineRenamed?.call(line, title);
              }
              Navigator.of(context).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    renameDialog.whenComplete(controller.dispose);
  }

  // ── Coverage badge for a line ──────────────────────────────────────────

  Widget? _buildCoverageBadge(_LineCoverageInfo? info) {
    if (info?.leaf == null) return null;
    final leaf = info!.leaf!;

    Color color;
    String text;

    switch (leaf.category) {
      case LeafCategory.covered:
        color = const Color(0xFF4CAF50);
        text = 'Covered';
      case LeafCategory.tooShallow:
        color = const Color(0xFFFFA726);
        text = 'Too shallow';
      case LeafCategory.tooDeep:
        color = const Color(0xFF42A5F5);
        text = '${leaf.excessPly} ply deep';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  // ── Unaccounted moves annotation ───────────────────────────────────────

  Widget? _buildUnaccountedAnnotation(_LineCoverageInfo? info) {
    if (info == null || info.unaccountedMoves.isEmpty) return null;

    // Group by position, show top few
    final groups = info.groupedUnaccounted.entries.toList();
    if (groups.isEmpty) return null;

    // Show unaccounted from at most 2 positions to avoid clutter
    final displayGroups = groups.take(2).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: displayGroups.map((group) {
        final moves = group.value
          ..sort((a, b) {
            if (a.gameCount != b.gameCount)
              return b.gameCount.compareTo(a.gameCount);
            return b.probability.compareTo(a.probability);
          });
        final displayMoves = moves.take(4).toList();
        final moveTexts = displayMoves.map((m) {
          if (m.gameCount > 0) {
            return '${m.move} (${_formatPercent(m.probability)})';
          }
          return '${m.move} (${_formatPercent(m.probability)}, ${m.source})';
        }).join('  ');

        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Unaccounted: ',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFFEF5350).withValues(alpha: 0.8),
                ),
              ),
              Expanded(
                child: Text(
                  moveTexts +
                      (moves.length > 4 ? '  +${moves.length - 4} more' : ''),
                  style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: const Color(0xFFEF5350).withValues(alpha: 0.7),
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  String _formatPercent(double p) => '${(p * 100).toStringAsFixed(1)}%';

  Widget _buildLineItem(RepertoireLine line, int index,
      {bool indented = false}) {
    final eventTitle = _extractEventTitle(line.fullPgn);
    final displayTitle =
        !_isPlaceholderTitle(eventTitle) ? eventTitle : line.name;

    final currentMoves = widget.currentMoveSequence;
    final matchDepth = _getPositionMatchDepth(line, currentMoves);
    final isExactMatch =
        matchDepth == currentMoves.length && currentMoves.isNotEmpty;

    final coverageInfo = _lineCoverage[line.id];
    final coverageBadge = widget.coverageResult != null
        ? _buildCoverageBadge(coverageInfo)
        : null;

    return InkWell(
      onTap: () => widget.onLineSelected?.call(line),
      child: Container(
        padding: EdgeInsets.only(
          left: indented ? 32 : 12,
          right: 12,
          top: 10,
          bottom: 10,
        ),
        decoration: BoxDecoration(
          color: isExactMatch
              ? Colors.blue[900]?.withValues(alpha: 0.3)
              : (index % 2 == 0 ? Colors.grey[900] : Colors.grey[850]),
          border: Border(
            left: isExactMatch
                ? BorderSide(color: Colors.blue[400]!, width: 3)
                : BorderSide.none,
            bottom: BorderSide(color: Colors.grey[800]!, width: 0.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    displayTitle,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.onLineRenamed != null)
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      icon: Icon(Icons.edit, size: 14, color: Colors.grey[500]),
                      padding: EdgeInsets.zero,
                      tooltip: 'Rename line',
                      onPressed: () => _showRenameDialog(line),
                    ),
                  ),
                if (coverageBadge != null) ...[
                  const SizedBox(width: 4),
                  coverageBadge,
                ],
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: line.color == 'white'
                        ? Colors.grey[200]
                        : Colors.grey[800],
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey[600]!, width: 0.5),
                  ),
                  child: Text(
                    line.color == 'white' ? 'W' : 'B',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: line.color == 'white'
                          ? Colors.grey[900]
                          : Colors.grey[200],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${line.moves.length} moves',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[500],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),

            _buildMovesPreview(line, matchDepth),

            // Unaccounted moves annotation
            if (widget.coverageResult != null)
              _buildUnaccountedAnnotation(coverageInfo) ??
                  const SizedBox.shrink(),

            if (line.comments.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '${line.comments.length} comment${line.comments.length == 1 ? '' : 's'}',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.green[400],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMovesPreview(RepertoireLine line, int matchDepth) {
    final moves = line.moves;
    final maxPreviewMoves = widget.isExpanded ? 12 : 8;

    return Wrap(
      spacing: 2,
      runSpacing: 2,
      children: [
        for (int i = 0; i < moves.length && i < maxPreviewMoves; i++) ...[
          if (i % 2 == 0)
            Text(
              '${(i ~/ 2) + 1}.',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[500],
                fontFamily: 'monospace',
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            decoration: BoxDecoration(
              color: i < matchDepth
                  ? Colors.blue[800]?.withValues(alpha: 0.5)
                  : null,
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              moves[i],
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: i < matchDepth ? Colors.blue[200] : Colors.grey[300],
                fontWeight:
                    i < matchDepth ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ],
        if (moves.length > maxPreviewMoves)
          Text(
            '... +${moves.length - maxPreviewMoves}',
            style: TextStyle(
              fontSize: 10,
              color: Colors.grey[500],
              fontStyle: FontStyle.italic,
            ),
          ),
      ],
    );
  }
}

/// Pre-computed coverage info for a single repertoire line
class _LineCoverageInfo {
  final LeafNode? leaf;
  final List<UnaccountedMove> unaccountedMoves;
  final Map<String, List<UnaccountedMove>> groupedUnaccounted;

  _LineCoverageInfo({
    this.leaf,
    this.unaccountedMoves = const [],
    this.groupedUnaccounted = const {},
  });
}

/// Dialog wrapper for full-screen repertoire lines browser
class RepertoireLinesBrowserDialog extends StatelessWidget {
  final List<RepertoireLine> lines;
  final List<String> currentMoveSequence;
  final Function(RepertoireLine line)? onLineSelected;
  final Function(RepertoireLine line, String newTitle)? onLineRenamed;
  final CoverageResult? coverageResult;

  const RepertoireLinesBrowserDialog({
    super.key,
    required this.lines,
    this.currentMoveSequence = const [],
    this.onLineSelected,
    this.onLineRenamed,
    this.coverageResult,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.8,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.grey[700]!, width: 1),
                ),
              ),
              child: Row(
                children: [
                  const Text(
                    'Browse Repertoire Lines',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: RepertoireLinesBrowser(
                lines: lines,
                currentMoveSequence: currentMoveSequence,
                isExpanded: true,
                coverageResult: coverageResult,
                onLineSelected: (line) {
                  onLineSelected?.call(line);
                  Navigator.of(context).pop();
                },
                onLineRenamed: onLineRenamed,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
