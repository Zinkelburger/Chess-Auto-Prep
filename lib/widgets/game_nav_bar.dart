/// Game navigation bar extracted from PGN viewer screen.
///
/// Shows star rating, sort dropdown, game counter, prev/next buttons,
/// and auto-play controls.
library;

import 'package:flutter/material.dart';

import '../models/pgn_filter_models.dart';
import 'shortcut_tooltip.dart';
import 'game_nav_item.dart';
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
  final int solitaireRevealCountdown;
  final VoidCallback? onReveal;
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
    this.solitaireRevealCountdown = 0,
    this.onReveal,
    this.onExitSolitaire,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: Colors.grey[700]!),
        ),
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
            _buildGameCounterDropdown(context),
            _buildSolitaireControls(context),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ShortcutTooltip(
              description: 'Previous game',
              shortcut: 'P',
              child: TextButton.icon(
                onPressed: currentIndex > 0 ? onPrev : null,
                icon: const Icon(Icons.skip_previous, size: 20),
                label: const Text('Prev'),
              ),
            ),
            const SizedBox(width: 16),
            ShortcutTooltip(
              description: 'Next game',
              shortcut: 'N',
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (solitaireWaitingForUser)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ShortcutTooltip(
              description: canReveal
                  ? 'Show the correct move'
                  : 'Available in ${countdown}s',
              shortcut: 'H',
              child: ActionChip(
                onPressed: canReveal ? onReveal : null,
                avatar: Icon(
                  Icons.visibility,
                  size: 16,
                  color: canReveal ? Colors.white : Colors.white60,
                ),
                label: Text(
                  canReveal ? 'Reveal' : '${countdown}s',
                  style: TextStyle(
                    fontSize: 12,
                    color: canReveal ? Colors.white : Colors.white60,
                  ),
                ),
                backgroundColor: canReveal
                    ? Colors.orange.withValues(alpha: 0.9)
                    : Colors.grey.withValues(alpha: 0.7),
                side: BorderSide.none,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ShortcutIconButton(
          description: 'Fullscreen',
          shortcut: 'Ctrl+F',
          onPressed: games.isNotEmpty ? onToggleFullScreen : null,
          icon: Icon(Icons.fullscreen, size: 24, color: Colors.grey[400]),
          visualDensity: VisualDensity.compact,
        ),
        const SizedBox(width: 4),
        ShortcutTooltip(
          description: 'Exit solitaire',
          shortcut: 'Shift+S',
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
            _buildGameCounterDropdown(context),
            _buildAutoPlayControls(),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ShortcutTooltip(
              description: 'Previous game',
              shortcut: 'P',
              child: TextButton.icon(
                onPressed: currentIndex > 0 ? onPrev : null,
                icon: const Icon(Icons.skip_previous, size: 20),
                label: const Text('Prev'),
              ),
            ),
            const SizedBox(width: 16),
            ShortcutTooltip(
              description: 'Annotate',
              shortcut: 'A',
              child: IconButton(
                onPressed: onToggleEditMode,
                icon: Icon(
                  Icons.edit_note,
                  size: 22,
                  color: isEditMode ? Colors.amber[600] : null,
                ),
                style: isEditMode
                    ? IconButton.styleFrom(
                        backgroundColor: Colors.amber.withValues(alpha: 0.12),
                      )
                    : null,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 16),
            ShortcutTooltip(
              description: 'Next game',
              shortcut: 'N',
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
          border: Border.all(color: Colors.grey[700]!),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sort, size: 16, color: Colors.grey[400]),
            const SizedBox(width: 4),
            Text(
              switch (sortMode) {
                GameSortMode.fileOrder => 'File order',
                GameSortMode.ratingDesc => 'Stars ↓',
                GameSortMode.ratingAsc => 'Stars ↑',
              },
              style: const TextStyle(fontSize: 11),
            ),
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
            color: star <= current ? Colors.amber : Colors.grey[600],
          ),
        ),
      );
    });
  }

  Widget _buildGameCounterDropdown(BuildContext context) {
    return Tooltip(
      message: 'Jump to game (S)',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: games.isEmpty
            ? null
            : () async {
                final selected = await showDialog<int>(
                  context: context,
                  builder: (_) => GameSearchDialog(
                    games: games,
                    currentIndex: currentIndex,
                  ),
                );
                if (selected != null) onGoToGame?.call(selected);
              },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.grey[700]!),
          ),
          child: Text(
            'Game ${currentIndex + 1} / ${games.length}',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
      ),
    );
  }

  Widget _buildAutoPlayControls() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ShortcutIconButton(
          description: isAutoPlaying ? 'Pause' : 'Watch game',
          shortcut: 'Space',
          onPressed: games.isNotEmpty ? onToggleAutoPlay : null,
          icon: Icon(
            isAutoPlaying ? Icons.pause_circle : Icons.play_circle,
            size: 28,
            color: isAutoPlaying ? Colors.amber : null,
          ),
        ),
        ShortcutIconButton(
          description: 'Fullscreen',
          shortcut: 'Ctrl+F',
          onPressed: games.isNotEmpty ? onToggleFullScreen : null,
          icon: Icon(Icons.fullscreen, size: 24, color: Colors.grey[400]),
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          onPressed: games.isNotEmpty ? onCopyPgn : null,
          icon: Icon(Icons.copy_outlined, size: 20, color: Colors.grey[400]),
          tooltip: 'Copy current game PGN',
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          onPressed: games.isNotEmpty && hasEphemeralAnnotations
              ? onClearAnnotations
              : null,
          icon: Icon(Icons.layers_clear_outlined,
              size: 20,
              color: hasEphemeralAnnotations
                  ? Colors.grey[400]
                  : Colors.grey[700]),
          tooltip: 'Clear analysis annotations',
          visualDensity: VisualDensity.compact,
        ),
        PopupMenuButton<double>(
          tooltip: 'Auto-play speed',
          icon: Icon(Icons.speed, size: 20, color: Colors.grey[400]),
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
          shortcut: 'W',
          child: FilterChip(
            label: const Text('Auto', style: TextStyle(fontSize: 11)),
            selected: autoNextGame,
            onSelected: onSetAutoNext,
            visualDensity: VisualDensity.compact,
          ),
        ),
      ],
    );
  }
}
