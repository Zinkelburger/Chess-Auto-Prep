/// Navigation strip under the repertoire tools column: go-to-start, back,
/// forward, generate-from-here, and flip-board buttons.
/// Split out of lib/screens/repertoire_screen.dart.
library;

import 'package:flutter/material.dart';

class RepertoireNavControls extends StatelessWidget {
  const RepertoireNavControls({
    super.key,
    required this.onGoToStart,
    required this.onGoBack,
    required this.onGoForward,
    required this.onGenerateFromHere,
    required this.onFlipBoard,
  });

  final VoidCallback onGoToStart;
  final VoidCallback onGoBack;
  final VoidCallback onGoForward;
  final VoidCallback onGenerateFromHere;
  final VoidCallback onFlipBoard;

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
        ],
      ),
    );
  }
}
