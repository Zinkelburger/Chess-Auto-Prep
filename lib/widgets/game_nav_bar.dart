/// Game navigation bar extracted from PGN viewer screen.
///
/// Shows star rating, sort dropdown, game counter, prev/next buttons,
/// and auto-play controls.
library;

import 'package:flutter/material.dart';

/// Sort mode for games in the nav bar.
enum GameSortMode {
  fileOrder,
  ratingDesc,
  ratingAsc,
}

/// Lightweight data class so the nav bar doesn't need the full game model.
class GameNavItem {
  final String label;
  final int studyRating;
  final String studySummary;

  const GameNavItem({
    required this.label,
    required this.studyRating,
    this.studySummary = '',
  });
}

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
  final ValueChanged<double>? onSetSpeed;
  final ValueChanged<bool>? onSetAutoNext;

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
    this.onSetSpeed,
    this.onSetAutoNext,
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
      child: Column(
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
              _buildGameCounterDropdown(),
              _buildAutoPlayControls(),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Tooltip(
                message: 'Previous game (P)',
                child: TextButton.icon(
                  onPressed: currentIndex > 0 ? onPrev : null,
                  icon: const Icon(Icons.skip_previous, size: 20),
                  label: const Text('Prev'),
                ),
              ),
              const SizedBox(width: 24),
              Tooltip(
                message: 'Next game (N)',
                child: TextButton.icon(
                  onPressed:
                      currentIndex < games.length - 1 ? onNext : null,
                  icon: const Icon(Icons.skip_next, size: 20),
                  label: const Text('Next'),
                ),
              ),
            ],
          ),
        ],
      ),
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
        message: 'Rate $star star${star > 1 ? 's' : ''} ($star)',
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

  Widget _buildGameCounterDropdown() {
    return PopupMenuButton<int>(
      tooltip: 'Jump to game',
      itemBuilder: (ctx) {
        final start = (currentIndex - 25).clamp(0, games.length);
        final end = (currentIndex + 25).clamp(0, games.length);
        return [
          for (int i = start; i < end; i++)
            PopupMenuItem(
              value: i,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${i + 1}.',
                          style: TextStyle(
                            fontWeight: i == currentIndex
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          games[i].label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: i == currentIndex
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (games[i].studyRating > 0)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(width: 4),
                            const Icon(Icons.star,
                                size: 14, color: Colors.amber),
                            Text(
                              '${games[i].studyRating}',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                    ],
                  ),
                  if (games[i].studySummary.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 36, top: 2),
                      child: Text(
                        games[i].studySummary,
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
        ];
      },
      onSelected: onGoToGame,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.grey[700]!),
        ),
        child: Text(
          'Game ${currentIndex + 1} / ${games.length}',
          style:
              const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
      ),
    );
  }

  Widget _buildAutoPlayControls() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: games.isNotEmpty ? onToggleAutoPlay : null,
          icon: Icon(
            isAutoPlaying ? Icons.pause_circle : Icons.play_circle,
            size: 28,
            color: isAutoPlaying ? Colors.amber : null,
          ),
          tooltip: isAutoPlaying ? 'Pause (Space)' : 'Watch game (Space)',
        ),
        IconButton(
          onPressed: games.isNotEmpty ? onToggleFullScreen : null,
          icon: Icon(Icons.fullscreen, size: 24, color: Colors.grey[400]),
          tooltip: 'Fullscreen (Ctrl+F)',
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
        Tooltip(
          message: 'Auto next game (A)',
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
