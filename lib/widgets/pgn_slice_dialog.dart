/// Slice dialog — filter a PGN game collection by board position and headers.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../utils/fen_utils.dart';

enum MatchMode { contains, exact, regex, after, before }

String _matchModeLabel(MatchMode m) {
  switch (m) {
    case MatchMode.contains:
      return 'contains';
    case MatchMode.exact:
      return 'exact';
    case MatchMode.regex:
      return 'regex';
    case MatchMode.after:
      return '≥ (after)';
    case MatchMode.before:
      return '≤ (before)';
  }
}

class _HeaderFilter {
  String field;
  MatchMode mode;
  String value;
  final TextEditingController controller;
  _HeaderFilter()
      : field = 'Black',
        mode = MatchMode.contains,
        value = '',
        controller = TextEditingController();
}

typedef GameRecord = ({Map<String, String> headers, String pgnText});

class PgnSliceDialog extends StatefulWidget {
  final List<GameRecord> allGames;
  final String currentFen;
  final void Function(List<int> matchingIndices) onApply;

  const PgnSliceDialog({
    super.key,
    required this.allGames,
    required this.currentFen,
    required this.onApply,
  });

  @override
  State<PgnSliceDialog> createState() => _PgnSliceDialogState();
}

class _PgnSliceDialogState extends State<PgnSliceDialog> {
  bool _usePositionFilter = false;
  final List<_HeaderFilter> _headerFilters = [];
  List<int> _matchingIndices = [];
  bool _computing = false;

  static const _startFen =
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -';

  static const _fieldOptions = [
    'White',
    'Black',
    'Event',
    'Date',
    'Result',
    'ECO',
    'StudyRating',
    'StudySummary',
  ];

  /// Match modes available per field. Date and StudyRating get comparison
  /// operators; other fields get text matching.
  static List<MatchMode> _modesForField(String field) {
    if (field == 'Date' || field == 'StudyRating') {
      return MatchMode.values;
    }
    return [MatchMode.contains, MatchMode.exact, MatchMode.regex];
  }

  @override
  void initState() {
    super.initState();
    _recompute();
  }

  bool get _isStartPosition => widget.currentFen == _startFen;

  void _addFilter() {
    setState(() => _headerFilters.add(_HeaderFilter()));
    _recompute();
  }

  void _removeFilter(int i) {
    setState(() {
      _headerFilters[i].controller.dispose();
      _headerFilters.removeAt(i);
    });
    _recompute();
  }

  void _recompute() {
    setState(() => _computing = true);
    final indices = <int>[];
    for (int i = 0; i < widget.allGames.length; i++) {
      if (_matchesGame(i)) indices.add(i);
    }
    setState(() {
      _matchingIndices = indices;
      _computing = false;
    });
  }

  bool _matchesGame(int index) {
    final game = widget.allGames[index];

    if (_usePositionFilter && !_isStartPosition) {
      if (!_gamePassesThroughPosition(game.pgnText, widget.currentFen)) {
        return false;
      }
    }

    for (final f in _headerFilters) {
      if (f.value.isEmpty) continue;
      final headerVal = game.headers[f.field] ?? '';
      if (!_matchesField(headerVal, f.value, f.mode)) return false;
    }
    return true;
  }

  static bool _gamePassesThroughPosition(String pgnText, String targetFen) {
    try {
      final game = PgnGame.parsePgn(pgnText);
      final mainline = game.moves.mainline().toList();
      Position pos = Chess.initial;
      if (normalizeFen(pos.fen) == targetFen) return true;
      for (final moveData in mainline) {
        final move = pos.parseSan(moveData.san);
        if (move == null) break;
        pos = pos.play(move);
        if (normalizeFen(pos.fen) == targetFen) return true;
      }
    } catch (_) {}
    return false;
  }

  static bool _matchesField(String headerVal, String query, MatchMode mode) {
    switch (mode) {
      case MatchMode.contains:
        return headerVal.toLowerCase().contains(query.toLowerCase());
      case MatchMode.exact:
        return headerVal.toLowerCase() == query.toLowerCase();
      case MatchMode.regex:
        try {
          return RegExp(query, caseSensitive: false).hasMatch(headerVal);
        } catch (_) {
          return false;
        }
      case MatchMode.after:
        return headerVal.compareTo(query) >= 0;
      case MatchMode.before:
        return headerVal.compareTo(query) <= 0;
    }
  }

  @override
  void dispose() {
    for (final f in _headerFilters) {
      f.controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Slice Dataset'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Position filter toggle
              SwitchListTile(
                title: const Text('Filter by board position'),
                subtitle: (_usePositionFilter && _isStartPosition)
                    ? const Text(
                        'Set a position on the board first, then re-open Slice',
                        style: TextStyle(fontSize: 12, color: Colors.orange),
                      )
                    : _usePositionFilter
                        ? Text(
                            'Only games passing through the current position',
                            style:
                                TextStyle(fontSize: 12, color: Colors.grey[400]),
                          )
                        : null,
                value: _usePositionFilter,
                onChanged: (v) {
                  setState(() => _usePositionFilter = v);
                  if (v && _isStartPosition) {
                    // Immediately turn it back off — can't filter on start pos
                    Future.microtask(() {
                      if (!mounted) return;
                      setState(() => _usePositionFilter = false);
                    });
                  } else {
                    _recompute();
                  }
                },
                dense: true,
              ),
              const Divider(),
              // Header filters
              Row(
                children: [
                  Text(
                    'Header Filters',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: Colors.grey[300],
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _addFilter,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add filter'),
                  ),
                ],
              ),
              if (_headerFilters.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No header filters. Click "Add filter" to narrow results.',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                ),
              for (int i = 0; i < _headerFilters.length; i++)
                _buildFilterRow(i),
              const SizedBox(height: 16),
              // Results preview
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[850],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[700]!),
                ),
                child: Row(
                  children: [
                    Icon(
                      _computing ? Icons.hourglass_top : Icons.filter_list,
                      size: 18,
                      color: Colors.grey[400],
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _computing
                          ? 'Computing...'
                          : '${_matchingIndices.length} / ${widget.allGames.length} games match',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: _matchingIndices.isEmpty
                            ? Colors.red[300]
                            : Colors.green[300],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            setState(() {
              _headerFilters.clear();
              _usePositionFilter = false;
            });
            _recompute();
          },
          child: const Text('Reset'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _matchingIndices.isNotEmpty
              ? () {
                  widget.onApply(_matchingIndices);
                  Navigator.pop(context);
                }
              : null,
          child: Text('Apply (${_matchingIndices.length})'),
        ),
      ],
    );
  }

  Widget _buildFilterRow(int index) {
    final f = _headerFilters[index];
    final availableModes = _modesForField(f.field);
    // If current mode isn't valid for this field, reset to first available
    if (!availableModes.contains(f.mode)) {
      f.mode = availableModes.first;
    }

    final hintText = (f.field == 'Date')
        ? 'e.g. 2000'
        : (f.field == 'StudyRating')
            ? 'e.g. 3'
            : 'Value...';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          // Field dropdown
          SizedBox(
            width: 120,
            child: DropdownButtonFormField<String>(
              initialValue: f.field,
              isDense: true,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                border: OutlineInputBorder(),
              ),
              items: _fieldOptions
                  .map((s) => DropdownMenuItem(
                      value: s,
                      child:
                          Text(s, style: const TextStyle(fontSize: 12))))
                  .toList(),
              onChanged: (v) {
                setState(() {
                  f.field = v!;
                  // Reset mode if not valid for new field
                  final modes = _modesForField(f.field);
                  if (!modes.contains(f.mode)) f.mode = modes.first;
                });
                _recompute();
              },
            ),
          ),
          const SizedBox(width: 6),
          // Match mode dropdown
          SizedBox(
            width: 120,
            child: DropdownButtonFormField<MatchMode>(
              initialValue: f.mode,
              isDense: true,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                border: OutlineInputBorder(),
              ),
              items: availableModes
                  .map((m) => DropdownMenuItem(
                        value: m,
                        child: Text(_matchModeLabel(m),
                            style: const TextStyle(fontSize: 12)),
                      ))
                  .toList(),
              onChanged: (v) {
                setState(() => f.mode = v!);
                _recompute();
              },
            ),
          ),
          const SizedBox(width: 6),
          // Value text field
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle: TextStyle(color: Colors.grey[600], fontSize: 12),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                border: const OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 12),
              onChanged: (v) {
                f.value = v;
                _recompute();
              },
              controller: f.controller,
            ),
          ),
          const SizedBox(width: 4),
          // Remove button
          IconButton(
            onPressed: () => _removeFilter(index),
            icon: const Icon(Icons.close, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }
}
