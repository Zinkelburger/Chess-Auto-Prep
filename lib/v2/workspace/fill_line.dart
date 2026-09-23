import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'fill_gaps.dart';

/// The one line the reading card gives a fill: what it is doing, or what
/// it did, with the one control that applies — Cancel while it runs, a
/// cross to take the outcome off the card. Nothing while there is no fill.
class FillLine extends StatelessWidget {
  const FillLine({super.key, required this.fill});

  final FillGaps fill;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: fill,
      builder: (context, _) {
        final theme = Theme.of(context);
        final (words, colour) = _describe(fill.state, theme.colorScheme);
        if (words == null) return const SizedBox.shrink();
        final running = fill.state is FillRunning;
        return SizedBox(
          height: engineBarHeight,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  words,
                  style: theme.textTheme.bodySmall?.copyWith(color: colour),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (running)
                TextButton(
                  onPressed:
                      fill.state is FillRunning &&
                          (fill.state as FillRunning).cancelling
                      ? null
                      : fill.cancel,
                  child: const Text('Cancel'),
                )
              else
                IconButton(
                  tooltip: 'Dismiss',
                  icon: const Icon(Icons.close, size: IconSize.menu),
                  onPressed: fill.dismiss,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// What the line says for [state], and its colour when it is not the usual
/// one; no words while there is no fill.
(String?, Color?) _describe(FillState state, ColorScheme scheme) =>
    switch (state) {
      FillIdle() => (null, null),
      FillRunning(:final nodes, :final depth, :final of, :final cancelling) => (
        cancelling
            ? 'Cancelling…'
            : 'Searching · depth $depth/$of · $nodes positions',
        null,
      ),
      FillDone(:final name, :final lines, :final traps, :final folded) => (
        [
          if (name == null)
            'Found ${_count(lines, 'line')}'
          else
            'Proposed ${_count(lines, 'line')} in $name',
          if (folded != 0) '$folded folded in',
          _count(traps, 'trap'),
        ].join(' · '),
        null,
      ),
      FillFailed(:final reason) => (reason, scheme.error),
    };

String _count(int n, String thing) => n == 1 ? '1 $thing' : '$n ${thing}s';
