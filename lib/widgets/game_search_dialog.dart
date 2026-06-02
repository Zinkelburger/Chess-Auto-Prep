/// Compact search dialog for jumping to a game in a large PGN collection.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'game_nav_item.dart';

const _maxResults = 5;
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

List<_SearchResult> _computeResults(List<GameNavItem> games, String query) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return [];

  final results = <_SearchResult>[];
  final seen = <int>{};
  final q = trimmed.toLowerCase();

  if (RegExp(r'^\d+$').hasMatch(trimmed)) {
    final n = int.parse(trimmed);
    final idx = n - 1;
    if (idx >= 0 && idx < games.length) {
      results.add(_SearchResult(
        index: idx,
        isGoToGame: true,
        goToLabel: 'Go to game $n',
      ));
      seen.add(idx);
    }
  }

  for (var i = 0; i < games.length && results.length < _maxResults; i++) {
    if (seen.contains(i)) continue;
    if (_buildSearchableText(games[i]).contains(q)) {
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

  List<_SearchResult> get _results =>
      _computeResults(widget.games, _controller.text);

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
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
    final query = _controller.text.trim();
    final results = _results;
    final current = widget.games[widget.currentIndex];

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
                  height: _maxResults * _resultRowHeight,
                  child: query.isEmpty
                      ? _buildEmptyHint(context, current)
                      : results.isEmpty
                          ? Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                'No matches',
                                style: TextStyle(
                                    color: Colors.grey[500], fontSize: 13),
                              ),
                            )
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: results
                                  .map((r) => _buildResultRow(context, r))
                                  .toList(),
                            ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyHint(BuildContext context, GameNavItem current) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Type to search',
          style: TextStyle(color: Colors.grey[500], fontSize: 13),
        ),
        const SizedBox(height: 10),
        _buildResultRow(
          context,
          _SearchResult(index: widget.currentIndex),
          interactive: false,
        ),
      ],
    );
  }

  Widget _buildResultRow(
    BuildContext context,
    _SearchResult result, {
    bool interactive = true,
  }) {
    final game = widget.games[result.index];
    final isCurrent = result.index == widget.currentIndex;
    final white = _playerName(game.headers, 'White');
    final black = _playerName(game.headers, 'Black');
    final secondary = _formatSecondaryLine(game.headers);
    final rating = game.studyRating;

    final borderColor = isCurrent
        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.6)
        : Colors.grey[700]!;
    final bgColor = isCurrent
        ? Theme.of(context)
            .colorScheme
            .primaryContainer
            .withValues(alpha: 0.25)
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
                if (!result.isGoToGame &&
                    !_isJunk(game.studySummary) &&
                    game.studySummary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      game.studySummary,
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

    if (!interactive) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: borderColor),
        ),
        child: content,
      );
    }

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
