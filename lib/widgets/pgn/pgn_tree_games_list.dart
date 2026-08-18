/// Games that reach the opening-tree cursor, with search and expandable PVs.
///
/// Each row is a title plus the comment-free mainline from this position,
/// truncated to one line. [expandAll] (default on) keeps every PV visible
/// and treats the blue triangle as a bullet; turning it off makes the
/// triangle a per-row preview toggle and the title opens the game.
library;

import 'package:flutter/material.dart';

import '../../models/pgn_game_entry.dart';
import '../../services/pgn_parsing_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/app_shortcuts.dart';
import '../../utils/fen_utils.dart';
import '../../utils/movetext_builder.dart';
import '../game_number_field.dart';
import '../game_search_dialog.dart';

class PgnTreeGamesList extends StatefulWidget {
  final List<PgnGameEntry> games;
  final String currentFen;
  final int currentIndex;
  final ValueChanged<int> onGameSelected;
  final VoidCallback onSearch;

  const PgnTreeGamesList({
    super.key,
    required this.games,
    required this.currentFen,
    required this.currentIndex,
    required this.onGameSelected,
    required this.onSearch,
  });

  @override
  State<PgnTreeGamesList> createState() => _PgnTreeGamesListState();
}

class _PgnTreeGamesListState extends State<PgnTreeGamesList> {
  bool _expandAll = true;
  final Set<int> _previewed = {};
  final Map<PgnGameEntry, String> _pvCache = {};
  String? _cachedFen;

  @override
  void didUpdateWidget(covariant PgnTreeGamesList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentFen != widget.currentFen) {
      _previewed.clear();
      _pvCache.clear();
      _cachedFen = null;
    }
  }

  bool _isExpanded(int index) => _expandAll || _previewed.contains(index);

  String _pvFor(PgnGameEntry game) {
    if (_cachedFen != widget.currentFen) {
      _pvCache.clear();
      _cachedFen = widget.currentFen;
    }
    return _pvCache.putIfAbsent(game, () {
      final fen = widget.currentFen;
      final sans = mainlineSansAfterFen(
        game.headers,
        game.pgnText,
        normalizeFen(fen),
      );
      if (sans.isEmpty) return '';
      return buildNumberedMovetext(
        sans,
        startMoveNumber: fullMoveNumber(fen),
        whiteToMoveFirst: isWhiteToMove(fen),
      );
    });
  }

  void _setExpandAll(bool value) {
    setState(() {
      _expandAll = value;
      if (!_expandAll) _previewed.clear();
    });
  }

  void _togglePreview(int index) {
    setState(() {
      if (!_previewed.remove(index)) _previewed.add(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final games = widget.games;
    if (games.isEmpty) return const SizedBox.shrink();
    final current = widget.currentIndex;

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.outline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'At this position',
                  style: AppTextStyles.caption.copyWith(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.onSurfaceSoft,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  alignment: WrapAlignment.start,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    GameNumberField(
                      currentIndex: current < 0 ? 0 : current,
                      gameCount: games.length,
                      onGoToGame: widget.onGameSelected,
                      tooltip:
                          'Games that reach this opening-tree position, '
                          'in the current sort.\n'
                          'Type a number and press Enter to open that game (G)',
                    ),
                    GameSearchButton(
                      shortcut: AppShortcut.searchGames,
                      onPressed: widget.onSearch,
                    ),
                    _ExpandAllToggle(
                      value: _expandAll,
                      onChanged: _setExpandAll,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 4),
              itemCount: games.length,
              itemBuilder: (context, idx) => _GameRow(
                game: games[idx],
                expanded: _isExpanded(idx),
                expandAll: _expandAll,
                pv: _isExpanded(idx) ? _pvFor(games[idx]) : '',
                onOpen: () => widget.onGameSelected(idx),
                onTogglePreview: () => _togglePreview(idx),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExpandAllToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ExpandAllToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: value
          ? 'Uncheck to collapse lines; the blue arrow then previews one'
          : 'Show every game\'s mainline from this position',
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: value,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (v) => onChanged(v ?? true),
              ),
              Text(
                'Expand all',
                style: AppTextStyles.caption.copyWith(fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GameRow extends StatelessWidget {
  final PgnGameEntry game;
  final bool expanded;
  final bool expandAll;
  final String pv;
  final VoidCallback onOpen;
  final VoidCallback onTogglePreview;

  const _GameRow({
    required this.game,
    required this.expanded,
    required this.expandAll,
    required this.pv,
    required this.onOpen,
    required this.onTogglePreview,
  });

  @override
  Widget build(BuildContext context) {
    const triangle = Icon(Icons.play_arrow, size: 14, color: AppColors.info);
    final body = _titleAndPv();
    final stars = _rating();

    if (expandAll) {
      return InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(padding: EdgeInsets.only(top: 1), child: triangle),
              const SizedBox(width: 6),
              Expanded(child: body),
              ?stars,
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 12, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            icon: triangle,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            visualDensity: VisualDensity.compact,
            tooltip: expanded ? 'Hide line' : 'Preview line',
            onPressed: onTogglePreview,
          ),
          Expanded(
            child: InkWell(
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: body,
              ),
            ),
          ),
          if (stars != null)
            Padding(padding: const EdgeInsets.only(top: 4), child: stars),
        ],
      ),
    );
  }

  Widget _titleAndPv() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          game.label,
          style: const TextStyle(fontSize: 11),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (expanded && pv.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              pv,
              style: const TextStyle(
                fontSize: 11,
                height: 1.2,
                color: AppColors.pgnMove,
              ),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  Widget? _rating() {
    if (game.studyRating <= 0) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.star, size: 12, color: AppColors.starAccent),
        Text('${game.studyRating}', style: const TextStyle(fontSize: 10)),
      ],
    );
  }
}
