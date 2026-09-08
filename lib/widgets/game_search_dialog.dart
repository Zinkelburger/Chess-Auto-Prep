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
import 'game_chapter_dialog.dart';
import 'game_number_field.dart';
import 'shortcut_tooltip.dart';

const _resultRowHeight = 62.0;

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
  'Date',
  'Round',
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
  final bool isCourse;

  const _GameEntry({
    required this.white,
    required this.black,
    required this.secondary,
    required this.summary,
    required this.rating,
    required this.searchText,
    required this.isCourse,
  });

  factory _GameEntry.fromGame(GameNavItem game) => _GameEntry(
    white: _playerName(game.headers, 'White'),
    black: _playerName(game.headers, 'Black'),
    secondary: _formatSecondaryLine(game.headers),
    summary: _isJunk(game.studySummary) ? '' : game.studySummary,
    rating: game.studyRating,
    searchText: _buildSearchableText(game),
    isCourse: _looksLikeCourse(game.headers),
  );
}

bool _looksLikeCourse(Map<String, String> headers) {
  final result = _header(headers, 'Result');
  final white = _header(headers, 'White');
  final hasRating =
      !_isJunk(_header(headers, 'WhiteElo')) ||
      !_isJunk(_header(headers, 'BlackElo'));
  return result == '*' && !hasRating && !_isJunk(white) && !white.contains(',');
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
  final parts = <String>[game.label, if (game.chapter != null) game.chapter!];
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
    final button = TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.search, size: 16),
      label: const Text('Search'),
      style: TextButton.styleFrom(
        foregroundColor: AppColors.onSurfaceMuted,
        iconSize: 16,
        minimumSize: const Size(0, kGameNavControlHeight),
        maximumSize: const Size(double.infinity, kGameNavControlHeight),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
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
  late final List<GameNavChapter> _groups = gameBrowserGroups(widget.games);
  GameNavChapter? _group;

  void _chooseGroup(GameNavChapter? group) {
    if (!mounted) return;
    setState(() {
      _group = group;
      _refreshResults();
    });
  }

  void _refreshResults() {
    final indices = _group?.gameIndices.toSet();
    _results = _computeResults(_entries, _lastQuery)
        .where((result) => indices == null || indices.contains(result.index))
        .toList();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: math.max(
      0,
      (widget.currentIndex - 3) * _resultRowHeight,
    ),
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    if (value == _lastQuery) return;
    if (!mounted) return;
    _lastQuery = value;
    setState(() {
      _refreshResults();
    });
  }

  void _select(int index) => Navigator.pop(context, index);

  void _onSubmitted() {
    final results = _results;
    if (results.isNotEmpty) _select(results.first.index);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final hasGroups = _groups.isNotEmpty;
    final wide = size.width >= 760;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context),
      },
      child: Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: math.min(hasGroups ? 1000 : 800, size.width - 48),
          height: math.min(740, size.height - 48),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('Browse Games', style: AppTextStyles.title),
                    ),
                    Text(
                      '${widget.games.length} games',
                      style: AppTextStyles.muted,
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      tooltip: 'Close game browser',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ListSearchField(
                  hintText: 'Search games or enter game #...',
                  autofocus: true,
                  onChanged: _onQueryChanged,
                  onSubmitted: _onSubmitted,
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: wide && hasGroups
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(width: 220, child: _buildGroups()),
                            const SizedBox(width: 24),
                            Expanded(child: _buildGames()),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (hasGroups)
                              SizedBox(
                                height: 52,
                                child: _buildGroups(horizontal: true),
                              ),
                            Expanded(child: _buildGames()),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGroups({bool horizontal = false}) => ListView(
    scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
    children: [
      _groupTile(null, horizontal),
      for (final group in _groups) _groupTile(group, horizontal),
    ],
  );

  Widget _groupTile(GameNavChapter? group, bool horizontal) {
    final selected = identical(_group, group);
    final count = group?.gameIndices.length ?? widget.games.length;
    return Padding(
      padding: EdgeInsets.only(bottom: 4, right: horizontal ? 8 : 0),
      child: SizedBox(
        width: horizontal ? 220 : null,
        child: Material(
          color: selected
              ? Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: 0.35)
              : AppColors.surfaceElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: selected ? AppColors.onSurfaceMuted : Colors.transparent,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _chooseGroup(group),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: group?.label ?? 'All games',
                      child: Text(
                        group?.label ?? 'All games',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodyStrong,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: '$count game${count == 1 ? '' : 's'}',
                    child: Text('$count', style: AppTextStyles.caption),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGames() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '${_group?.label ?? 'All games'} · ${_results.length} shown',
        style: AppTextStyles.muted,
      ),
      const SizedBox(height: 12),
      Expanded(
        child: _results.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('No matches', style: AppTextStyles.muted),
                    if (_group != null)
                      TextButton(
                        onPressed: () => _chooseGroup(null),
                        child: const Text('Search all games'),
                      ),
                  ],
                ),
              )
            : ListView.builder(
                controller: _scroll,
                padding: EdgeInsets.zero,
                itemCount: _results.length,
                itemBuilder: (context, i) =>
                    _buildResultRow(context, _results[i]),
              ),
      ),
    ],
  );

  Widget _buildResultRow(BuildContext context, _SearchResult result) {
    final entry = _entries[result.index];
    final isCurrent = result.index == widget.currentIndex;
    final white = entry.white;
    final black = entry.black;
    final secondary = entry.secondary;
    final courseHeadline = black == '?' || black == white ? white : black;
    final courseSecondary = black == '?' || black == white
        ? secondary
        : [white, secondary].where((s) => s.isNotEmpty).join(' · ');

    final borderColor = isCurrent
        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.6)
        : Colors.transparent;
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
                      : entry.isCourse
                      ? courseHeadline
                      : '$white vs $black',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!result.isGoToGame &&
                    (entry.isCourse ? courseSecondary : secondary).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      entry.isCourse ? courseSecondary : secondary,
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
