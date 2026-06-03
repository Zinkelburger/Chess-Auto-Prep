/// Fullscreen game playback view extracted from PGN viewer screen.
///
/// Shows a board that fills the screen with auto-hiding overlay bars
/// for game info (top) and playback controls (bottom).
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import 'chess_board_widget.dart';
import 'game_nav_bar.dart' show kAutoPlaySpeeds;

class FullscreenGameView extends StatelessWidget {
  final Position position;
  final bool boardFlipped;
  final String gameLabel;
  final int currentIndex;
  final int totalGames;
  final bool isAutoPlaying;
  final double autoPlayDelaySec;
  final bool autoNextGame;

  final ValueChanged<String>? onBoardMove;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback? onGoBack;
  final VoidCallback? onGoForward;
  final VoidCallback? onToggleAutoPlay;
  final VoidCallback? onExit;
  final ValueChanged<double>? onSetSpeed;
  final ValueChanged<bool>? onSetAutoNext;

  const FullscreenGameView({
    super.key,
    required this.position,
    required this.boardFlipped,
    required this.gameLabel,
    required this.currentIndex,
    required this.totalGames,
    required this.isAutoPlaying,
    required this.autoPlayDelaySec,
    required this.autoNextGame,
    this.onBoardMove,
    this.onPrev,
    this.onNext,
    this.onGoBack,
    this.onGoForward,
    this.onToggleAutoPlay,
    this.onExit,
    this.onSetSpeed,
    this.onSetAutoNext,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: ChessBoardWidget(
                position: position,
                flipped: boardFlipped,
                onMove: onBoardMove != null
                    ? (move) => onBoardMove!(move.san)
                    : null,
              ),
            ),
          ),
          // Game info overlay at top
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _OverlayBar(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withAlpha(180),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        gameLabel,
                        style: TextStyle(
                          color: Colors.white.withAlpha(200),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (totalGames > 1)
                      Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Text(
                          '${currentIndex + 1} / $totalGames',
                          style: TextStyle(
                            color: Colors.white.withAlpha(140),
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // Controls overlay at bottom
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _OverlayBar(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withAlpha(180),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: currentIndex > 0 ? onPrev : null,
                      icon: Icon(Icons.skip_previous,
                          color: Colors.white.withAlpha(180)),
                      tooltip: 'Previous game (P)',
                    ),
                    IconButton(
                      onPressed: onGoBack,
                      icon: Icon(Icons.chevron_left,
                          color: Colors.white.withAlpha(180)),
                      tooltip: 'Back (←)',
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: onToggleAutoPlay,
                      icon: Icon(
                        isAutoPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        size: 40,
                        color: isAutoPlaying
                            ? Colors.amber
                            : Colors.white.withAlpha(220),
                      ),
                      tooltip: isAutoPlaying
                          ? 'Pause (Space)'
                          : 'Watch game (Space)',
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: onGoForward,
                      icon: Icon(Icons.chevron_right,
                          color: Colors.white.withAlpha(180)),
                      tooltip: 'Forward (→)',
                    ),
                    IconButton(
                      onPressed: currentIndex < totalGames - 1
                          ? onNext
                          : null,
                      icon: Icon(Icons.skip_next,
                          color: Colors.white.withAlpha(180)),
                      tooltip: 'Next game (N)',
                    ),
                    const SizedBox(width: 12),
                    PopupMenuButton<double>(
                      tooltip: 'Auto-play speed',
                      icon: Icon(Icons.speed,
                          size: 20,
                          color: Colors.white.withAlpha(160)),
                      color: Colors.grey[900],
                      onSelected: onSetSpeed,
                      itemBuilder: (ctx) => [
                        for (final s in kAutoPlaySpeeds)
                          PopupMenuItem(
                            value: s,
                            child: Row(
                              children: [
                                if (s == autoPlayDelaySec)
                                  const Icon(Icons.check,
                                      size: 16, color: Colors.amber)
                                else
                                  const SizedBox(width: 16),
                                const SizedBox(width: 8),
                                Text('${s}s / move',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13)),
                              ],
                            ),
                          ),
                      ],
                    ),
                    Tooltip(
                      message: 'Auto next game (W)',
                      child: GestureDetector(
                        onTap: () =>
                            onSetAutoNext?.call(!autoNextGame),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: autoNextGame
                                ? Colors.amber.withAlpha(40)
                                : Colors.white.withAlpha(15),
                            border: Border.all(
                              color: autoNextGame
                                  ? Colors.amber.withAlpha(120)
                                  : Colors.white.withAlpha(40),
                            ),
                          ),
                          child: Text(
                            'Auto',
                            style: TextStyle(
                              fontSize: 11,
                              color: autoNextGame
                                  ? Colors.amber
                                  : Colors.white.withAlpha(160),
                              fontWeight: autoNextGame
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Exit fullscreen button (always visible, top-right)
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              onPressed: onExit,
              icon: Icon(Icons.fullscreen_exit,
                  color: Colors.white.withAlpha(120), size: 28),
              tooltip: 'Exit fullscreen (Esc)',
            ),
          ),
        ],
      ),
    );
  }
}

/// Overlay bar that fades in on mouse hover and fades out after inactivity.
class _OverlayBar extends StatefulWidget {
  final Widget child;

  const _OverlayBar({required this.child});

  @override
  State<_OverlayBar> createState() => _OverlayBarState();
}

class _OverlayBarState extends State<_OverlayBar> {
  bool _visible = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _onHover() {
    if (!_visible) {
      setState(() => _visible = true);
    }
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (_) => _onHover(),
      onEnter: (_) => _onHover(),
      child: AnimatedOpacity(
        opacity: _visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 400),
        child: IgnorePointer(
          ignoring: !_visible,
          child: widget.child,
        ),
      ),
    );
  }
}
