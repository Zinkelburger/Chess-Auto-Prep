/// Navigation strip under the repertoire tools column: go-to-start, back,
/// forward, generate-from-here, and flip-board buttons.
/// Split out of lib/screens/repertoire_screen.dart.
library;

import 'package:flutter/material.dart';

import '../../models/board_size.dart';

class RepertoireNavControls extends StatelessWidget {
  const RepertoireNavControls({
    super.key,
    required this.onGoToStart,
    required this.onGoBack,
    required this.onGoForward,
    required this.onGenerateFromHere,
    required this.onFlipBoard,
    this.boardSize,
    this.onBoardSizeChanged,
  });

  final VoidCallback onGoToStart;
  final VoidCallback onGoBack;
  final VoidCallback onGoForward;
  final VoidCallback onGenerateFromHere;
  final VoidCallback onFlipBoard;

  /// Current board column size; null hides the board-size button (compact
  /// layout stacks the board above the tools, so there is nothing to trade).
  final BoardSize? boardSize;
  final ValueChanged<BoardSize>? onBoardSizeChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous, size: 16),
            onPressed: onGoToStart,
            tooltip: 'Go to start',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 20),
            onPressed: onGoBack,
            tooltip: 'Back (←)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 20),
            onPressed: onGoForward,
            tooltip: 'Forward (→)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: onGenerateFromHere,
            icon: const Icon(Icons.add, size: 16),
            tooltip: 'Generate line from here',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.flip, size: 14),
            onPressed: onFlipBoard,
            tooltip: 'Flip board (F)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          if (boardSize != null && onBoardSizeChanged != null)
            PopupMenuButton<BoardSize>(
              tooltip: 'Board size: ${boardSize!.label}',
              position: PopupMenuPosition.over,
              padding: EdgeInsets.zero,
              onSelected: onBoardSizeChanged,
              itemBuilder: (_) => [
                for (final size in BoardSize.values)
                  CheckedPopupMenuItem<BoardSize>(
                    value: size,
                    checked: size == boardSize,
                    child: Text(size.label),
                  ),
              ],
              child: const SizedBox(
                width: 28,
                height: 28,
                child: Icon(Icons.aspect_ratio, size: 15),
              ),
            ),
        ],
      ),
    );
  }
}
