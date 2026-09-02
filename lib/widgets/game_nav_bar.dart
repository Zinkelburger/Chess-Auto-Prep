/// Game navigation bar extracted from PGN viewer screen.
///
/// Shows star rating, sort dropdown, game counter, prev/next buttons,
/// and auto-play controls.
library;

import 'package:flutter/material.dart';

import '../utils/app_shortcuts.dart';

import '../models/pgn_filter_models.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import 'labeled_toggle.dart';
import 'shortcut_tooltip.dart';
import 'game_nav_item.dart';
import 'game_number_field.dart';
import 'game_search_dialog.dart';

export '../models/pgn_filter_models.dart' show GameSortMode;
export 'game_nav_item.dart' show GameNavItem;

/// Speed options shared between the nav bar and fullscreen overlay.
const kAutoPlaySpeeds = [0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 10.0];

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

  // Solitaire mode props
  final bool isSolitaireMode;
  final bool solitaireWaitingForUser;
  final bool solitaireCanReveal;
  final bool solitaireCanHint;
  final int solitaireRevealCountdown;
  final VoidCallback? onReveal;
  final VoidCallback? onHint;
  final VoidCallback? onExitSolitaire;

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
    this.solitaireWaitingForUser = false,
    this.solitaireCanReveal = false,
    this.solitaireCanHint = false,
    this.solitaireRevealCountdown = 0,
    this.onReveal,
    this.onHint,
    this.onExitSolitaire,
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
            _buildSolitaireControls(context),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ShortcutTooltip(
              description: 'Previous game',
              shortcut: AppShortcut.previousItem,
              child: TextButton.icon(
                onPressed: currentIndex > 0 ? onPrev : null,
                icon: const Icon(Icons.skip_previous, size: 20),
                label: const Text('Prev'),
              ),
            ),
            const SizedBox(width: 16),
            ShortcutTooltip(
              description: 'Next game',
              shortcut: AppShortcut.nextItem,
              child: TextButton.icon(
                onPressed: currentIndex < games.length - 1 ? onNext : null,
                icon: const Icon(Icons.skip_next, size: 20),
                label: const Text('Next'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSolitaireControls(BuildContext context) {
    final canReveal = solitaireCanReveal;
    final countdown = solitaireRevealCountdown;
    final waitingText = countdown > 0
        ? 'Available in ${countdown}s'
        : 'Available on your turn';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Both always visible so the controls are discoverable; grayed out
        // until they can be used (countdown running or opponent to move).
        // The countdown sits in its own fixed-width slot so the chips do not
        // change width every second.
        if (countdown > 0)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: SizedBox(
              width: 34,
              child: Text(
                '${countdown}s',
                textAlign: TextAlign.right,
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.onSurfaceMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ShortcutTooltip(
            description: solitaireCanHint
                ? 'Show which piece moves (counts against first-try)'
                : waitingText,
            shortcut: AppShortcut.hintMove,
            child: ActionChip(
              onPressed: solitaireCanHint ? onHint : null,
              avatar: Icon(
                Icons.lightbulb_outline,
                size: 16,
                color: solitaireCanHint
                    ? AppColors.ink
                    : AppColors.onSurfaceDisabled,
              ),
              label: Text(
                'Hint',
                style: TextStyle(
                  fontSize: 12,
                  color: solitaireCanHint
                      ? AppColors.ink
                      : AppColors.onSurfaceDisabled,
                ),
              ),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ShortcutTooltip(
            description: canReveal
                ? 'Give up and show the correct move'
                : waitingText,
            shortcut: AppShortcut.revealMove,
            child: ActionChip(
              onPressed: canReveal ? onReveal : null,
              avatar: Icon(
                Icons.visibility,
                size: 16,
                color: canReveal
                    ? AppColors.onWarning
                    : AppColors.onSurfaceDisabled,
              ),
              label: Text(
                'Reveal',
                style: TextStyle(
                  fontSize: 12,
                  color: canReveal
                      ? AppColors.onWarning
                      : AppColors.onSurfaceDisabled,
                ),
              ),
              backgroundColor: canReveal
                  ? AppColors.warningSurface.withValues(alpha: 0.9)
                  : AppColors.onSurfaceMuted.withValues(alpha: 0.4),
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
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
        const SizedBox(width: 4),
        ShortcutTooltip(
          description: 'Exit solitaire',
          shortcut: AppShortcut.leave,
          child: ActionChip(
            onPressed: onExitSolitaire,
            avatar: const Icon(Icons.close, size: 16),
            label: const Text('Exit', style: TextStyle(fontSize: 12)),
            visualDensity: VisualDensity.compact,
          ),
        ),
      ],
    );
  }

  Widget _buildNormalLayout(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 4,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ..._buildStarRating(currentRating),
                const SizedBox(width: 8),
                _buildSortDropdown(),
              ],
            ),
            _buildGameCounter(context),
            _buildAutoPlayControls(),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ShortcutTooltip(
              description: 'Previous game',
              shortcut: AppShortcut.previousItem,
              child: TextButton.icon(
                onPressed: currentIndex > 0 ? onPrev : null,
                icon: const Icon(Icons.skip_previous, size: 20),
                label: const Text('Prev'),
              ),
            ),
            const SizedBox(width: 16),
            ShortcutTooltip(
              description: 'Amend game',
              shortcut: AppShortcut.amendGame,
              child: IconButton(
                onPressed: onToggleEditMode,
                icon: Icon(
                  Icons.edit_note,
                  size: 22,
                  color: isEditMode ? AppColors.starAccent : null,
                ),
                style: isEditMode
                    ? IconButton.styleFrom(
                        backgroundColor: AppColors.starAccent.withValues(
                          alpha: 0.12,
                        ),
                      )
                    : null,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 16),
            ShortcutTooltip(
              description: 'Next game',
              shortcut: AppShortcut.nextItem,
              child: TextButton.icon(
                onPressed: currentIndex < games.length - 1 ? onNext : null,
                icon: const Icon(Icons.skip_next, size: 20),
                label: const Text('Next'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSortDropdown() {
    return PopupMenuButton<GameSortMode>(
      tooltip: 'Sort games',
      onSelected: onSetSortMode,
      itemBuilder: (ctx) => [
        for (final mode in GameSortMode.values)
          PopupMenuItem(
            value: mode,
            child: Row(
              children: [
                if (mode == sortMode)
                  const Icon(Icons.check, size: 16)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(switch (mode) {
                  GameSortMode.fileOrder => 'File order',
                  GameSortMode.dateDesc => 'Newest first',
                  GameSortMode.ratingDesc => 'Stars (high first)',
                  GameSortMode.ratingAsc => 'Stars (low first)',
                }),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sort, size: 16, color: AppColors.onSurfaceSoft),
            const SizedBox(width: 4),
            Text(switch (sortMode) {
              GameSortMode.fileOrder => 'File order',
              GameSortMode.dateDesc => 'Newest first',
              GameSortMode.ratingDesc => 'Stars ↓',
              GameSortMode.ratingAsc => 'Stars ↑',
            }, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildStarRating(int current) {
    return List.generate(5, (i) {
      final star = i + 1;
      return Tooltip(
        message: 'Rate $star star${star > 1 ? 's' : ''}',
        child: GestureDetector(
          onTap: () => onSetRating?.call(current == star ? 0 : star),
          child: Icon(
            star <= current ? Icons.star : Icons.star_border,
            size: 22,
            color: star <= current ? AppColors.starAccent : AppColors.starEmpty,
          ),
        ),
      );
    });
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
        const SizedBox(width: 8),
        GameSearchButton(
          shortcut: AppShortcut.searchGames,
          onPressed: games.isEmpty ? null : () => _openGameSearch(context),
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

  Widget _buildAutoPlayControls() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
        IconButton(
          onPressed: games.isNotEmpty ? onCopyPgn : null,
          icon: const Icon(
            Icons.copy_outlined,
            size: 20,
            color: AppColors.onSurfaceSoft,
          ),
          tooltip: 'Copy current game PGN',
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          onPressed: games.isNotEmpty && hasEphemeralAnnotations
              ? onClearAnnotations
              : null,
          icon: Icon(
            Icons.layers_clear_outlined,
            size: 20,
            color: hasEphemeralAnnotations
                ? AppColors.onSurfaceSoft
                : AppColors.onSurfaceDisabled,
          ),
          tooltip: 'Clear analysis annotations',
          visualDensity: VisualDensity.compact,
        ),
        PopupMenuButton<double>(
          tooltip: 'Auto-play speed',
          icon: const Icon(
            Icons.speed,
            size: 20,
            color: AppColors.onSurfaceSoft,
          ),
          onSelected: onSetSpeed,
          itemBuilder: (ctx) => [
            for (final s in kAutoPlaySpeeds)
              PopupMenuItem(
                value: s,
                child: Row(
                  children: [
                    if (s == autoPlayDelaySec)
                      const Icon(Icons.check, size: 16)
                    else
                      const SizedBox(width: 16),
                    const SizedBox(width: 8),
                    Text('${s}s / move'),
                  ],
                ),
              ),
          ],
        ),
        ShortcutTooltip(
          description: 'Auto next game',
          shortcut: AppShortcut.autoNextGame,
          child: AppSwitch(
            label: 'Auto',
            value: autoNextGame,
            onChanged: (v) => onSetAutoNext?.call(v),
            enabled: onSetAutoNext != null,
          ),
        ),
      ],
    );
  }
}
