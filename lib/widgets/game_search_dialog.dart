/// Compact search dialog for jumping to a game in a large PGN collection.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'game_nav_item.dart';

const _visibleRows = 10;
const _dialogWidth = 380.0;
const _resultRowHeight = 58.0;

const _junkValues = {
  '',
  '?',
  '??',
  '????.??.??',
  'nn',
  'repertoire',
  'opponent',
  'white',
  'black',
};

const _searchHeaderKeys = [
  'White',
  'Black',
  'Event',
  'ECO',
  'Opening',
  'Variation',
  'Site',
];

class _SearchResult {
  final int index;
  final bool isGoToGame;
  final String? goToLabel;

  const _SearchResult({
    required this.index,
    this.isGoToGame = false,
    this.goToLabel,
  });
}

/// Display + search data computed once per game, so scrolling and searching
/// never re-parse headers or run date regexes on the fly.
class _GameEntry {
  final String white;
  final String black;
  final String secondary;
  final String summary;
  final int rating;
  final String searchText;

  const _GameEntry({
    required this.white,
    required this.black,
    required this.secondary,
    required this.summary,
    required this.rating,
    required this.searchText,
  });

  factory _GameEntry.fromGame(GameNavItem game) => _GameEntry(
        white: _playerName(game.headers, 'White'),
        black: _playerName(game.headers, 'Black'),
        secondary: _formatSecondaryLine(game.headers),
        summary: _isJunk(game.studySummary) ? '' : game.studySummary,
        rating: game.studyRating,
        searchText: _buildSearchableText(game),
      );
}

bool _isJunk(String? value) {
  if (value == null) return true;
  final t = value.trim();
  if (t.isEmpty) return true;
  return _junkValues.contains(t.toLowerCase());
}

String _header(Map<String, String> headers, String key) =>
    headers[key]?.trim() ?? '';

String _playerName(Map<String, String> headers, String key) {
  final v = _header(headers, key);
  return _isJunk(v) ? '?' : v;
}

String _buildSearchableText(GameNavItem game) {
  final parts = <String>[];
  for (final key in _searchHeaderKeys) {
    final v = _header(game.headers, key);
    if (!_isJunk(v)) parts.add(v);
  }
  if (!_isJunk(game.studySummary)) parts.add(game.studySummary);
  return parts.join(' ').toLowerCase();
}

String _formatDate(String raw) {
  final t = raw.trim();
  if (_isJunk(t)) return '';
  if (RegExp(r'^\?+$').hasMatch(t.replaceAll('.', ''))) return '';
  final segments = t.split('.');
  if (segments.length == 3) {
    final year = segments[0];
    final month = segments[1];
    final day = segments[2];
    final yearOnly = !_isJunk(year) &&
        (RegExp(r'^\?+$').hasMatch(month) || _isJunk(month)) &&
        (RegExp(r'^\?+$').hasMatch(day) || _isJunk(day));
    if (yearOnly) return year;
  }
  return t;
}

String _formatSecondaryLine(Map<String, String> headers) {
  final parts = <String>[];
  final event = _header(headers, 'Event');
  if (!_isJunk(event)) parts.add(event);
  final site = _header(headers, 'Site');
  if (!_isJunk(site)) parts.add(site);
  final date = _formatDate(_header(headers, 'Date'));
  if (date.isNotEmpty) parts.add(date);
  return parts.join(' · ');
}

List<_SearchResult> _computeResults(List<_GameEntry> entries, String query) {
  final trimmed = query.trim();

  final results = <_SearchResult>[];
  final seen = <int>{};

  // With no query, show every game so the list is browsable by default.
  if (trimmed.isEmpty) {
    for (var i = 0; i < entries.length; i++) {
      results.add(_SearchResult(index: i));
    }
    return results;
  }

  final q = trimmed.toLowerCase();

  if (RegExp(r'^\d+$').hasMatch(trimmed)) {
    final n = int.parse(trimmed);
    final idx = n - 1;
    if (idx >= 0 && idx < entries.length) {
      results.add(_SearchResult(
        index: idx,
        isGoToGame: true,
        goToLabel: 'Go to game $n',
      ));
      seen.add(idx);
    }
  }

  for (var i = 0; i < entries.length; i++) {
    if (seen.contains(i)) continue;
    if (entries[i].searchText.contains(q)) {
      results.add(_SearchResult(index: i));
      seen.add(i);
    }
  }

  return results;
}

class GameSearchDialog extends StatefulWidget {
  final List<GameNavItem> games;
  final int currentIndex;

  const GameSearchDialog({
    super.key,
    required this.games,
    required this.currentIndex,
  });

  @override
  State<GameSearchDialog> createState() => _GameSearchDialogState();
}

class _GameSearchDialogState extends State<GameSearchDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  // Display/search data precomputed once so scrolling and typing stay smooth.
  late final List<_GameEntry> _entries =
      widget.games.map(_GameEntry.fromGame).toList();

  // Results cached and only recomputed when the query text changes.
  late List<_SearchResult> _results = _computeResults(_entries, '');
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  void _onQueryChanged() {
    if (_controller.text == _lastQuery) return;
    _lastQuery = _controller.text;
    setState(() {
      _results = _computeResults(_entries, _controller.text);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _select(int index) => Navigator.pop(context, index);

  void _onSubmitted(String _) {
    final results = _results;
    if (results.isNotEmpty) _select(results.first.index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final results = _results;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context),
      },
      child: Dialog(
        backgroundColor: theme.colorScheme.surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _dialogWidth),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Search games or enter game #...',
                    hintStyle: TextStyle(color: Colors.grey[600], fontSize: 13),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
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
                      borderSide: BorderSide(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  style: const TextStyle(fontSize: 14),
                  onSubmitted: _onSubmitted,
                  textInputAction: TextInputAction.go,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  // Show up to _visibleRows at once, but never taller than the
                  // window allows (leaving room for the search field + margins).
                  height: math.min(
                    _visibleRows * _resultRowHeight,
                    MediaQuery.of(context).size.height - 220,
                  ).clamp(_resultRowHeight, _visibleRows * _resultRowHeight),
                  child: results.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            'No matches',
                            style: TextStyle(
                                color: Colors.grey[500], fontSize: 13),
                          ),
                        )
                      : ListView.builder(
                          padding: EdgeInsets.zero,
                          itemCount: results.length,
                          itemBuilder: (context, i) =>
                              _buildResultRow(context, results[i]),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResultRow(BuildContext context, _SearchResult result) {
    final entry = _entries[result.index];
    final isCurrent = result.index == widget.currentIndex;
    final white = entry.white;
    final black = entry.black;
    final secondary = entry.secondary;
    final rating = entry.rating;

    final borderColor = isCurrent
        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.6)
        : Colors.grey[700]!;
    final bgColor = isCurrent
        ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.25)
        : Colors.transparent;

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Text(
              '${result.index + 1}',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[500],
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  result.isGoToGame
                      ? (result.goToLabel ?? 'Go to game ${result.index + 1}')
                      : '$white vs $black',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!result.isGoToGame && secondary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      secondary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[500],
                      ),
                    ),
                  ),
                if (!result.isGoToGame && entry.summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      entry.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[500],
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (rating > 0)
            Text(
              '★' * rating,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.amber,
                letterSpacing: -1,
              ),
            ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: bgColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: borderColor),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _select(result.index),
          child: content,
        ),
      ),
    );
  }
}
