/// Game navigation bar extracted from PGN viewer screen.
///
/// Shows star rating, sort dropdown, game counter, prev/next buttons,
/// and auto-play controls.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/app_shortcuts.dart';

import '../models/pgn_filter_models.dart';
import '../theme/app_colors.dart';
import 'shortcut_tooltip.dart';
import 'game_nav_item.dart';
import 'game_number_field.dart';
import 'game_search_dialog.dart';

export '../models/pgn_filter_models.dart' show GameSortMode;
export 'game_nav_item.dart' show GameNavItem;

/// Speed options shared between the nav bar and fullscreen overlay.
const kAutoPlaySpeeds = [0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 10.0];

const _previousGameShortcut = AppShortcut([
  KeyChord(LogicalKeyboardKey.arrowUp),
]);
const _nextGameShortcut = AppShortcut([KeyChord(LogicalKeyboardKey.arrowDown)]);

class GameNavBar extends StatelessWidget {
  final List<GameNavItem> games;
  final int currentIndex;
  final int currentRating;
  final GameSortMode sortMode;
  final bool isAutoPlaying;
  final double autoPlayDelaySec;
  final bool autoNextGame;

  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final ValueChanged<int>? onGoToGame;
  final ValueChanged<int>? onSetRating;
  final ValueChanged<GameSortMode>? onSetSortMode;
  final VoidCallback? onToggleAutoPlay;
  final VoidCallback? onToggleFullScreen;
  final VoidCallback? onCopyPgn;
  final VoidCallback? onClearAnnotations;
  final bool hasEphemeralAnnotations;
  final ValueChanged<double>? onSetSpeed;
  final ValueChanged<bool>? onSetAutoNext;
  final VoidCallback? onToggleEditMode;
  final bool isEditMode;

  /// Solitaire strips the bar back to moving between games: the stars, the
  /// sort, auto-play and amend all belong to reading a collection, and Hint /
  /// Reveal live in the status strip beside the "your move" cue rather than
  /// at the far end of the pane.
  final bool isSolitaireMode;

  const GameNavBar({
    super.key,
    required this.games,
    required this.currentIndex,
    required this.currentRating,
    required this.sortMode,
    required this.isAutoPlaying,
    required this.autoPlayDelaySec,
    required this.autoNextGame,
    this.onPrev,
    this.onNext,
    this.onGoToGame,
    this.onSetRating,
    this.onSetSortMode,
    this.onToggleAutoPlay,
    this.onToggleFullScreen,
    this.onCopyPgn,
    this.onClearAnnotations,
    this.hasEphemeralAnnotations = false,
    this.onSetSpeed,
    this.onSetAutoNext,
    this.onToggleEditMode,
    this.isEditMode = false,
    this.isSolitaireMode = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: const Border(top: BorderSide(color: AppColors.outline)),
      ),
      child: isSolitaireMode
          ? _buildSolitaireLayout(context)
          : _buildNormalLayout(context),
    );
  }

  Widget _buildSolitaireLayout(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 4,
          children: [
            _buildGameCounter(context),
            ShortcutIconButton(
              description: 'Fullscreen',
              shortcut: AppShortcut.fullScreen,
              onPressed: games.isNotEmpty ? onToggleFullScreen : null,
              icon: const Icon(
                Icons.fullscreen,
                size: 24,
                color: AppColors.onSurfaceSoft,
              ),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 4),
        _buildPrevNextRow(),
      ],
    );
  }

  Widget _buildPrevNextRow({Widget? middle}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ShortcutTooltip(
          description: 'Previous game',
          shortcut: _previousGameShortcut,
          child: TextButton.icon(
            onPressed: currentIndex > 0 ? onPrev : null,
            icon: const Icon(Icons.skip_previous, size: 20),
            label: const Text('Prev'),
          ),
        ),
        if (middle != null) ...[const SizedBox(width: 16), middle],
        const SizedBox(width: 16),
        ShortcutTooltip(
          description: 'Next game',
          shortcut: _nextGameShortcut,
          child: TextButton.icon(
            onPressed: currentIndex < games.length - 1 ? onNext : null,
            icon: const Icon(Icons.skip_next, size: 20),
            label: const Text('Next'),
          ),
        ),
      ],
    );
  }

  Widget _buildNormalLayout(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final navigator = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ShortcutIconButton(
              description: 'Previous game',
              shortcut: _previousGameShortcut,
              onPressed: currentIndex > 0 ? onPrev : null,
              icon: const Icon(Icons.chevron_left, size: 24),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 2),
            _buildGameCounter(context),
            const SizedBox(width: 2),
            ShortcutIconButton(
              description: 'Next game',
              shortcut: _nextGameShortcut,
              onPressed: currentIndex < games.length - 1 ? onNext : null,
              icon: const Icon(Icons.chevron_right, size: 24),
              visualDensity: VisualDensity.compact,
            ),
          ],
        );
        final readingActions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GameSearchButton(
              shortcut: AppShortcut.searchGames,
              onPressed: games.isEmpty ? null : () => _openGameSearch(context),
            ),
            ShortcutIconButton(
              description: isAutoPlaying ? 'Pause' : 'Watch game',
              shortcut: AppShortcut.autoPlay,
              onPressed: games.isNotEmpty ? onToggleAutoPlay : null,
              icon: Icon(
                isAutoPlaying ? Icons.pause_circle : Icons.play_circle,
                size: 28,
                color: isAutoPlaying ? AppColors.starAccent : null,
              ),
            ),
            _buildMoreMenu(context),
          ],
        );

        // On a normal viewer pane the game coordinate stays truly centered;
        // the rating and reading tools are independently edge-aligned. This
        // avoids the visibly drifting "Game N of total" caused by Wrap's
        // unequal children.
        if (constraints.maxWidth >= 640) {
          return SizedBox(
            height: 40,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: _buildRatingMenu(),
                ),
                navigator,
                Align(alignment: Alignment.centerRight, child: readingActions),
              ],
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            navigator,
            const SizedBox(height: 4),
            Row(children: [_buildRatingMenu(), const Spacer(), readingActions]),
          ],
        );
      },
    );
  }

  /// Five stars in a row: tap the n-th to rate, tap the current rating again
  /// to clear it. A menu for this needed a click to open, a read down a list
  /// of star strings and a click to choose; the row is one click and the
  /// rating is visible without opening anything.
  Widget _buildRatingMenu() {
    final enabled = onSetRating != null;
    return Tooltip(
      message: 'Rate this game (1–5). Tap the current star again to unrate.',
      waitDuration: const Duration(milliseconds: 500),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var star = 1; star <= 5; star++)
            InkWell(
              onTap: enabled
                  ? () => onSetRating?.call(star == currentRating ? 0 : star)
                  : null,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                child: Icon(
                  star <= currentRating ? Icons.star : Icons.star_border,
                  size: 20,
                  color: star <= currentRating
                      ? AppColors.starAccent
                      : AppColors.starEmpty,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGameCounter(BuildContext context) {
    // The counter is a position in *this* order, and the order is the sort
    // dropdown's — say so. "Game 301 of 312" with no ordering named is the one
    // number on this bar nobody can interpret.
    final ordering = switch (sortMode) {
      GameSortMode.fileOrder => 'in file order',
      GameSortMode.dateDesc => 'newest first',
      GameSortMode.ratingDesc => 'by stars, high first',
      GameSortMode.ratingAsc => 'by stars, low first',
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GameNumberField(
          currentIndex: currentIndex,
          gameCount: games.length,
          onGoToGame: onGoToGame,
          tooltip:
              'Game ${currentIndex + 1} of ${games.length}, $ordering.\n'
              'Type a game number and press Enter to jump there (G)',
        ),
      ],
    );
  }

  Future<void> _openGameSearch(BuildContext context) async {
    final selected = await showGameSearchDialog(
      context: context,
      games: games,
      currentIndex: currentIndex,
    );
    if (selected != null) onGoToGame?.call(selected);
  }

  Widget _buildMoreMenu(BuildContext context) {
    return MenuAnchor(
      builder: (context, controller, child) => IconButton(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.tune, size: 20),
        tooltip: 'Reading options',
        visualDensity: VisualDensity.compact,
      ),
      menuChildren: [
        SubmenuButton(
          menuChildren: [
            for (final mode in GameSortMode.values)
              MenuItemButton(
                onPressed: () => onSetSortMode?.call(mode),
                leadingIcon: Icon(
                  mode == sortMode ? Icons.check : null,
                  size: 16,
                ),
                child: Text(switch (mode) {
                  GameSortMode.fileOrder => 'File order',
                  GameSortMode.dateDesc => 'Newest first',
                  GameSortMode.ratingDesc => 'Stars, high first',
                  GameSortMode.ratingAsc => 'Stars, low first',
                }),
              ),
          ],
          leadingIcon: const Icon(Icons.sort, size: 18),
          child: const Text('Sort games'),
        ),
        SubmenuButton(
          menuChildren: [
            for (final speed in kAutoPlaySpeeds)
              MenuItemButton(
                onPressed: onSetSpeed == null
                    ? null
                    : () => onSetSpeed?.call(speed),
                leadingIcon: Icon(
                  speed == autoPlayDelaySec ? Icons.check : null,
                  size: 16,
                ),
                child: Text('${speed}s per move'),
              ),
          ],
          leadingIcon: const Icon(Icons.speed, size: 18),
          child: Text('Playback speed · ${autoPlayDelaySec}s'),
        ),
        CheckboxMenuButton(
          value: autoNextGame,
          onChanged: onSetAutoNext == null
              ? null
              : (value) {
                  if (value != null) onSetAutoNext?.call(value);
                },
          child: const Text('Continue to next game'),
        ),
        const Divider(height: 8),
        MenuItemButton(
          onPressed: onToggleFullScreen,
          leadingIcon: const Icon(Icons.fullscreen, size: 18),
          child: const Text('Fullscreen'),
        ),
        MenuItemButton(
          onPressed: onCopyPgn,
          leadingIcon: const Icon(Icons.copy_outlined, size: 18),
          child: const Text('Copy game PGN'),
        ),
        if (hasEphemeralAnnotations)
          MenuItemButton(
            onPressed: onClearAnnotations,
            leadingIcon: const Icon(Icons.layers_clear_outlined, size: 18),
            child: const Text('Clear analysis marks'),
          ),
        MenuItemButton(
          onPressed: onToggleEditMode,
          leadingIcon: Icon(
            isEditMode ? Icons.edit : Icons.edit_outlined,
            size: 18,
            color: isEditMode ? AppColors.starAccent : null,
          ),
          child: Text(isEditMode ? 'Finish amending' : 'Amend game'),
        ),
      ],
    );
  }
}
