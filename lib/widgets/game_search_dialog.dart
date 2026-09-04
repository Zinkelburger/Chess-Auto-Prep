/// Compact search dialog for jumping to a game in a large PGN collection.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_shortcuts.dart';
import 'common/list_search_field.dart';
import 'game_nav_item.dart';
import 'game_number_field.dart';
import 'shortcut_tooltip.dart';

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
    final yearOnly =
        !_isJunk(year) &&
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
      results.add(
        _SearchResult(index: idx, isGoToGame: true, goToLabel: 'Go to game $n'),
      );
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

/// Opens [GameSearchDialog] and returns the chosen 0-based index, or null
/// if dismissed. Empty lists do not open a dialog.
Future<int?> showGameSearchDialog({
  required BuildContext context,
  required List<GameNavItem> games,
  required int currentIndex,
}) {
  if (games.isEmpty) return Future.value(null);
  final safeIndex = currentIndex.clamp(0, games.length - 1);
  return showDialog<int>(
    context: context,
    builder: (_) => GameSearchDialog(games: games, currentIndex: safeIndex),
  );
}

/// Labeled search control next to [GameNumberField].
///
/// Number jump and text search stay two controls on purpose: the counter is
/// "where am I / go to N", and this button is "find by player, event, or
/// opening". Merging them into one field hides the current position while
/// you type and makes "12" mean both game 12 and a text query.
class GameSearchButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final AppShortcut? shortcut;

  const GameSearchButton({super.key, required this.onPressed, this.shortcut});

  @override
  Widget build(BuildContext context) {
    // Same outline, radius, and type as [GameNumberField] so the pair reads
    // as one control group instead of a padded CTA next to a compact box.
    final button = OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.search, size: 16),
      label: const Text('Search'),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.ink,
        iconSize: 16,
        minimumSize: const Size(0, kGameNavControlHeight),
        maximumSize: const Size(double.infinity, kGameNavControlHeight),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        side: const BorderSide(color: AppColors.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    );
    const description = 'Search games by player, event or opening';
    final shortcut = this.shortcut;
    if (shortcut == null) {
      return Tooltip(message: description, child: button);
    }
    return ShortcutTooltip(
      description: description,
      shortcut: shortcut,
      child: button,
    );
  }
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
  // Display/search data precomputed once so scrolling and typing stay smooth.
  late final List<_GameEntry> _entries = widget.games
      .map(_GameEntry.fromGame)
      .toList();

  // Results cached and only recomputed when the query text changes.
  late List<_SearchResult> _results = _computeResults(_entries, '');
  String _lastQuery = '';

  void _onQueryChanged(String value) {
    if (value == _lastQuery) return;
    if (!mounted) return;
    _lastQuery = value;
    setState(() {
      _results = _computeResults(_entries, value);
    });
  }

  void _select(int index) => Navigator.pop(context, index);

  void _onSubmitted() {
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
                ListSearchField(
                  hintText: 'Search games or enter game #...',
                  autofocus: true,
                  onChanged: _onQueryChanged,
                  onSubmitted: _onSubmitted,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  // Show up to _visibleRows at once, but never taller than the
                  // window allows (leaving room for the search field + margins).
                  height: math
                      .min(
                        _visibleRows * _resultRowHeight,
                        MediaQuery.sizeOf(context).height - 220,
                      )
                      .clamp(_resultRowHeight, _visibleRows * _resultRowHeight),
                  child: results.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            'No matches',
                            style: TextStyle(
                              color: AppColors.onSurfaceMuted,
                              fontSize: 13,
                            ),
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
        : AppColors.outline;
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
            child: Text('${result.index + 1}', style: AppTextStyles.caption),
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
                      style: AppTextStyles.caption,
                    ),
                  ),
                if (!result.isGoToGame && entry.summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      entry.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.onSurfaceMuted,
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
                color: AppColors.starAccent,
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
