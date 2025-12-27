/// Repertoire Lines Browser Widget
/// A comprehensive view of all lines in a repertoire with filtering,
/// grouping, and detailed previews
library;

import 'package:flutter/material.dart';
import '../models/repertoire_line.dart';

/// Groups lines by their opening structure for better organization
class LineGroup {
  final String name;
  final String prefix; // Common move prefix
  final List<RepertoireLine> lines;
  
  LineGroup({
    required this.name,
    required this.prefix,
    required this.lines,
  });
  
  int get totalMoves => lines.fold(0, (sum, line) => sum + line.moves.length);
}

class RepertoireLinesBrowser extends StatefulWidget {
  final List<RepertoireLine> lines;
  final List<String> currentMoveSequence;
  final Function(RepertoireLine line)? onLineSelected;
  final bool isExpanded; // For inline vs fullscreen mode

  const RepertoireLinesBrowser({
    super.key,
    required this.lines,
    this.currentMoveSequence = const [],
    this.onLineSelected,
    this.isExpanded = false,
  });

  @override
  State<RepertoireLinesBrowser> createState() => _RepertoireLinesBrowserState();
}

class _RepertoireLinesBrowserState extends State<RepertoireLinesBrowser> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  List<RepertoireLine> _filteredLines = [];
  Map<String, List<RepertoireLine>> _groupedLines = {};
  Set<String> _expandedGroups = {};
  
  // Filter options
  bool _showOnlyMatchingPosition = true;
  String _sortBy = 'name'; // 'name', 'length', 'position'

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _filterAndGroupLines();
  }

  @override
  void didUpdateWidget(RepertoireLinesBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lines != widget.lines ||
        oldWidget.currentMoveSequence != widget.currentMoveSequence) {
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

  void _filterAndGroupLines() {
    final searchTerm = _searchController.text.toLowerCase().trim();
    final currentMoves = widget.currentMoveSequence;

    // Step 1: Filter lines
    var filtered = widget.lines.where((line) {
      // Position filter
      if (_showOnlyMatchingPosition && currentMoves.isNotEmpty) {
        if (!_lineMatchesPosition(line, currentMoves)) {
          return false;
        }
      }

      // Search term filter
      if (searchTerm.isNotEmpty) {
        final lineName = line.name.toLowerCase();
        final eventTitle = _extractEventTitle(line.fullPgn).toLowerCase();
        final movesString = line.moves.join(' ').toLowerCase();
        final formattedMoves = _formatMovesForSearch(line.moves).toLowerCase();

        return lineName.contains(searchTerm) ||
               eventTitle.contains(searchTerm) ||
               movesString.contains(searchTerm) ||
               formattedMoves.contains(searchTerm);
      }

      return true;
    }).toList();

    // Step 2: Sort
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

    // Step 3: Group by opening prefix
    final grouped = <String, List<RepertoireLine>>{};
    for (final line in filtered) {
      final groupName = _getGroupName(line);
      grouped.putIfAbsent(groupName, () => []).add(line);
    }

    setState(() {
      _filteredLines = filtered;
      _groupedLines = grouped;
      
      // Auto-expand groups with matches at current position
      if (currentMoves.isNotEmpty) {
        for (final entry in grouped.entries) {
          final hasExactMatch = entry.value.any((l) => 
            l.moves.length >= currentMoves.length &&
            _lineMatchesPosition(l, currentMoves)
          );
          if (hasExactMatch) {
            _expandedGroups.add(entry.key);
          }
        }
      }
    });
  }

  bool _lineMatchesPosition(RepertoireLine line, List<String> currentMoves) {
    if (currentMoves.isEmpty) return true;
    if (currentMoves.length > line.moves.length) return false;

    for (int i = 0; i < currentMoves.length; i++) {
      if (line.moves[i] != currentMoves[i]) {
        return false;
      }
    }
    return true;
  }

  int _getPositionMatchDepth(RepertoireLine line, List<String> currentMoves) {
    int depth = 0;
    for (int i = 0; i < currentMoves.length && i < line.moves.length; i++) {
      if (line.moves[i] == currentMoves[i]) {
        depth++;
      } else {
        break;
      }
    }
    return depth;
  }

  String _getGroupName(RepertoireLine line) {
    // Try to extract opening name from event/title
    final eventTitle = _extractEventTitle(line.fullPgn);
    if (eventTitle.isNotEmpty && eventTitle != 'Repertoire Line') {
      // Take first part before colon or dash for grouping
      final parts = eventTitle.split(RegExp(r'[:\-–]'));
      if (parts.isNotEmpty) {
        return parts[0].trim();
      }
      return eventTitle;
    }

    // Fallback: group by first 2 moves
    if (line.moves.length >= 2) {
      return '1.${line.moves[0]} ${line.moves[1]}';
    } else if (line.moves.isNotEmpty) {
      return '1.${line.moves[0]}';
    }
    return 'Other';
  }

  String _extractEventTitle(String pgn) {
    final lines = pgn.split('\n');
    for (final line in lines) {
      if (line.trim().startsWith('[Title ')) {
        return _extractHeaderValue(line) ?? '';
      }
    }
    for (final line in lines) {
      if (line.trim().startsWith('[Event ')) {
        return _extractHeaderValue(line) ?? '';
      }
    }
    return '';
  }

  String? _extractHeaderValue(String line) {
    final start = line.indexOf('"') + 1;
    final end = line.lastIndexOf('"');
    if (start > 0 && end > start) {
      return line.substring(start, end);
    }
    return null;
  }

  String _formatMovesForSearch(List<String> moves) {
    final buffer = StringBuffer();
    for (int i = 0; i < moves.length; i++) {
      if (i % 2 == 0) {
        buffer.write('${(i ~/ 2) + 1}.');
      }
      buffer.write(moves[i]);
      buffer.write(' ');
    }
    return buffer.toString().trim();
  }

  String _formatMoves(List<String> moves, {int? highlightUpTo}) {
    final buffer = StringBuffer();
    for (int i = 0; i < moves.length; i++) {
      if (i % 2 == 0) {
        if (i > 0) buffer.write(' ');
        buffer.write('${(i ~/ 2) + 1}.');
      }
      buffer.write(moves[i]);
      if (i < moves.length - 1 && i % 2 == 1) buffer.write(' ');
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header with search and filters
        _buildHeader(),
        
        // Stats bar
        _buildStatsBar(),
        
        // Lines list
        Expanded(
          child: _filteredLines.isEmpty
              ? _buildEmptyState()
              : _buildLinesList(),
        ),
      ],
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
          // Title row
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
              // Filter toggle
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
          
          // Search field
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search by name, moves (e.g., "1.e4 e5" or "Sicilian")...',
              hintStyle: TextStyle(color: Colors.grey[500], fontSize: 12),
              prefixIcon: Icon(Icons.search, size: 18, color: Colors.grey[500]),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear, size: 18, color: Colors.grey[500]),
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
          
          // Sort options
          Row(
            children: [
              Text('Sort: ', style: TextStyle(fontSize: 11, color: Colors.grey[400])),
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
    final matchingCount = _filteredLines.where((l) => 
      _lineMatchesPosition(l, currentMoves)
    ).length;
    
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
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 48, color: Colors.grey[600]),
            const SizedBox(height: 16),
            Text(
              _searchController.text.isNotEmpty
                  ? 'No lines match your search'
                  : _showOnlyMatchingPosition
                      ? 'No lines match the current position'
                      : 'No lines in repertoire',
              style: TextStyle(color: Colors.grey[500]),
              textAlign: TextAlign.center,
            ),
            if (_showOnlyMatchingPosition && widget.currentMoveSequence.isNotEmpty) ...[
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
    // If only one group, show flat list
    if (_groupedLines.length <= 1) {
      return ListView.builder(
        controller: _scrollController,
        itemCount: _filteredLines.length,
        itemBuilder: (context, index) {
          return _buildLineItem(_filteredLines[index], index);
        },
      );
    }

    // Multiple groups - show expandable sections
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

  Widget _buildGroupSection(String groupName, List<RepertoireLine> lines, bool isExpanded) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Group header
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
        
        // Expanded lines
        if (isExpanded)
          ...lines.asMap().entries.map((entry) => 
            _buildLineItem(entry.value, entry.key, indented: true)
          ),
      ],
    );
  }

  Widget _buildLineItem(RepertoireLine line, int index, {bool indented = false}) {
    final eventTitle = _extractEventTitle(line.fullPgn);
    final displayTitle = eventTitle.isNotEmpty && eventTitle != 'Repertoire Line' 
        ? eventTitle 
        : line.name;
    
    final currentMoves = widget.currentMoveSequence;
    final matchDepth = _getPositionMatchDepth(line, currentMoves);
    final isExactMatch = matchDepth == currentMoves.length && currentMoves.isNotEmpty;
    final isPrefixMatch = matchDepth > 0 && matchDepth < currentMoves.length;
    
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
              ? Colors.blue[900]?.withOpacity(0.3)
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
            // Title row
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
                const SizedBox(width: 8),
                // Color indicator
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: line.color == 'white' ? Colors.grey[200] : Colors.grey[800],
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey[600]!, width: 0.5),
                  ),
                  child: Text(
                    line.color == 'white' ? 'W' : 'B',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: line.color == 'white' ? Colors.grey[900] : Colors.grey[200],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Move count
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
            
            // Moves preview with highlighting
            _buildMovesPreview(line, matchDepth),
            
            // Comments preview if any
            if (line.comments.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '💬 ${line.comments.length} comment${line.comments.length == 1 ? '' : 's'}',
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
          // Move number for white's moves
          if (i % 2 == 0)
            Text(
              '${(i ~/ 2) + 1}.',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[500],
                fontFamily: 'monospace',
              ),
            ),
          // The move itself
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            decoration: BoxDecoration(
              color: i < matchDepth 
                  ? Colors.blue[800]?.withOpacity(0.5) 
                  : null,
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              moves[i],
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: i < matchDepth ? Colors.blue[200] : Colors.grey[300],
                fontWeight: i < matchDepth ? FontWeight.bold : FontWeight.normal,
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

/// Dialog wrapper for full-screen repertoire lines browser
class RepertoireLinesBrowserDialog extends StatelessWidget {
  final List<RepertoireLine> lines;
  final List<String> currentMoveSequence;
  final Function(RepertoireLine line)? onLineSelected;

  const RepertoireLinesBrowserDialog({
    super.key,
    required this.lines,
    this.currentMoveSequence = const [],
    this.onLineSelected,
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
            // Dialog header
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
            
            // Browser content
            Expanded(
              child: RepertoireLinesBrowser(
                lines: lines,
                currentMoveSequence: currentMoveSequence,
                isExpanded: true,
                onLineSelected: (line) {
                  onLineSelected?.call(line);
                  Navigator.of(context).pop();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}












