/// Game navigation bar extracted from PGN viewer screen.
///
/// Keeps game selection separate from move navigation.
library;

import 'package:flutter/material.dart';

import '../utils/app_shortcuts.dart';

import '../models/pgn_filter_models.dart';
import 'shortcut_tooltip.dart';
import 'game_nav_item.dart';
import 'game_number_field.dart';
import 'game_search_dialog.dart';

export '../models/pgn_filter_models.dart' show GameSortMode;
export 'game_nav_item.dart' show GameNavItem;

/// Speed options shared between the nav bar and fullscreen overlay.
const kAutoPlaySpeeds = [0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 10.0];

/// Collection navigation; optional tools live in the page's View menu.
class GameNavBar extends StatelessWidget {
  final List<GameNavItem> games;
  final int currentIndex;
  final GameSortMode sortMode;
  final bool isAutoPlaying;
  final bool showPlayback;
  final bool isSolitaireMode;
  final Widget? trailing;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final ValueChanged<int>? onGoToGame;
  final VoidCallback? onToggleAutoPlay;

  const GameNavBar({
    super.key,
    required this.games,
    required this.currentIndex,
    this.sortMode = GameSortMode.fileOrder,
    this.isAutoPlaying = false,
    this.showPlayback = false,
    this.isSolitaireMode = false,
    this.onPrev,
    this.onNext,
    this.onGoToGame,
    this.onToggleAutoPlay,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ShortcutIconButton(
              description: 'Previous game',
              shortcut: AppShortcut.previousItem,
              onPressed: currentIndex > 0 ? onPrev : null,
              icon: const Icon(Icons.chevron_left),
            ),
            _buildCounter(context),
            ShortcutIconButton(
              description: 'Next game',
              shortcut: AppShortcut.nextItem,
              onPressed: currentIndex < games.length - 1 ? onNext : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        if (!isSolitaireMode)
          GameSearchButton(
            shortcut: AppShortcut.searchGames,
            onPressed: games.isEmpty ? null : () => _openGameSearch(context),
          ),
        if (!isSolitaireMode && (showPlayback || isAutoPlaying))
          TextButton.icon(
            onPressed: onToggleAutoPlay,
            icon: Icon(
              isAutoPlaying ? Icons.pause : Icons.play_arrow,
              size: 18,
            ),
            label: Text(isAutoPlaying ? 'Pause' : 'Play'),
          ),
        ?trailing,
      ],
    ),
  );

  Widget _buildCounter(BuildContext context) {
    final canBrowse =
        !isSolitaireMode && games.isNotEmpty && onGoToGame != null;
    final hasChapters = games.any((game) => game.chapter != null);
    final number = GameNumberField(
      currentIndex: currentIndex,
      gameCount: games.length,
      onGoToGame: onGoToGame,
      tooltip: canBrowse
          ? null
          : actionTooltip(
              'Game ${currentIndex + 1} of ${games.length}. Type a number to jump',
              shortcut: AppShortcut.goToGameNumber,
            ),
    );
    if (!canBrowse) return number;
    return Tooltip(
      message: hasChapters
          ? 'Browse chapters. ${actionTooltip('Type a game number to jump', shortcut: AppShortcut.goToGameNumber)}'
          : 'Browse games. ${actionTooltip('Type a game number to jump', shortcut: AppShortcut.goToGameNumber)}',
      child: InkWell(
        key: const Key('game-counter-browser'),
        borderRadius: BorderRadius.circular(6),
        onTap: () => _openGameSearch(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [number, const Icon(Icons.arrow_drop_down, size: 18)],
        ),
      ),
    );
  }

  Future<void> _openGameSearch(BuildContext context) async {
    final selected = await showGameSearchDialog(
      context: context,
      games: games,
      currentIndex: currentIndex,
    );
    if (!context.mounted) return;
    if (selected != null) onGoToGame?.call(selected);
  }
}
