import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'solitaire.dart';
import '../ui/app_keys.dart';
import '../ui/move_notation.dart';

/// The Solitaire tab: the setup before a start, the guess being made while
/// one runs, and what was missed once the game is through.
class SolitairePane extends StatelessWidget {
  const SolitairePane({
    super.key,
    required this.solitaire,
    this.onNextGame,
    this.onAddToStudy,
  });

  final Solitaire solitaire;

  /// Puts the next game of the file on the board, when there is one.
  final VoidCallback? onNextGame;

  /// Keeps the game just guessed in a study.
  final VoidCallback? onAddToStudy;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: solitaire,
    builder: (context, _) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        readingCardInset,
        Space.m,
        readingCardInset,
        Space.l,
      ),
      child: !solitaire.active
          ? _Setup(solitaire: solitaire)
          : solitaire.finished
          ? _Done(
              solitaire: solitaire,
              onNextGame: onNextGame,
              onAddToStudy: onAddToStudy,
            )
          : _Guessing(solitaire: solitaire),
    ),
  );
}

class _Setup extends StatelessWidget {
  const _Setup({required this.solitaire});
  final Solitaire solitaire;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (!solitaire.canOffer) {
      return Text(
        'Open a game to play it as solitaire.',
        style: text.bodyMedium,
      );
    }
    final count = solitaire.movesToGuess;
    final side = solitaire.side == Side.white ? 'White' : 'Black';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Guess the game’s moves one at a time. The other side’s moves are '
          'played for you.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: Space.l),
        _Row(
          label: 'Guess for',
          child: SegmentedButton<Side>(
            key: const ValueKey('solitaire-side'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: Side.white, label: Text('White')),
              ButtonSegment(value: Side.black, label: Text('Black')),
            ],
            selected: {solitaire.side},
            onSelectionChanged: (value) => solitaire.setSide(value.first),
          ),
        ),
        const SizedBox(height: Space.m),
        _Row(
          label: 'Start at',
          child: SegmentedButton<bool>(
            key: const ValueKey('solitaire-start'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: true, label: Text('Move 1')),
              ButtonSegment(value: false, label: Text('This move')),
            ],
            selected: {solitaire.fromStart},
            onSelectionChanged: (value) => solitaire.setFromStart(value.first),
          ),
        ),
        const SizedBox(height: Space.m),
        Text(
          count == 1
              ? '1 $side move to guess.'
              : '$count $side moves to guess.',
          style: text.bodySmall,
        ),
        const SizedBox(height: Space.m),
        FilledButton.icon(
          key: const ValueKey('solitaire-begin'),
          onPressed: count == 0 ? null : solitaire.start,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start solitaire'),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 88,
        child: Text(label, style: Theme.of(context).textTheme.bodySmall),
      ),
      Flexible(child: child),
    ],
  );
}

class _Guessing extends StatelessWidget {
  const _Guessing({required this.solitaire});
  final Solitaire solitaire;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final side = solitaire.side == Side.white ? 'White' : 'Black';
    final feedback = solitaire.feedback;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Find $side’s move', style: text.titleMedium),
        const SizedBox(height: Space.s),
        // Each line keeps its height whether it has words or not, so the
        // buttons never move under the pointer.
        SizedBox(
          height: 20,
          child: Text(
            displaySan(context, feedback ?? ''),
            style: text.bodyMedium?.copyWith(
              color: solitaire.lastWrong ? scheme.error : null,
            ),
          ),
        ),
        SizedBox(
          height: 20,
          child: Text(
            displaySan(context, solitaire.hint ?? ''),
            style: text.bodyMedium,
          ),
        ),
        const SizedBox(height: Space.m),
        Wrap(
          spacing: Space.s,
          runSpacing: Space.s,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('solitaire-hint'),
              onPressed: solitaire.hint == null ? solitaire.showHint : null,
              icon: const Icon(Icons.lightbulb_outline),
              label: const Text('Hint'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('solitaire-reveal'),
              onPressed: solitaire.reveal,
              icon: const Icon(Icons.visibility_outlined),
              label: const Text('Show move'),
            ),
            Tooltip(
              message: AppKey.leave.tip('Stop solitaire'),
              child: TextButton(
                onPressed: solitaire.stop,
                child: const Text('Stop'),
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.l),
        Text(
          '${solitaire.guessed} guessed · ${solitaire.firstTry} first try',
          style: text.bodySmall,
        ),
      ],
    );
  }
}

class _Done extends StatelessWidget {
  const _Done({required this.solitaire, this.onNextGame, this.onAddToStudy});
  final Solitaire solitaire;
  final VoidCallback? onNextGame;
  final VoidCallback? onAddToStudy;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final parts = [
      '${solitaire.firstTry}/${solitaire.guessed} first try',
      if (solitaire.hinted > 0) '${solitaire.hinted} hinted',
      if (solitaire.revealed > 0) '${solitaire.revealed} shown',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Complete — ${parts.join(', ')}', style: text.titleMedium),
        const SizedBox(height: Space.m),
        Wrap(
          spacing: Space.s,
          runSpacing: Space.s,
          children: [
            OutlinedButton(
              onPressed: solitaire.again,
              child: const Text('Play again'),
            ),
            if (onNextGame != null)
              OutlinedButton(
                onPressed: onNextGame,
                child: const Text('Next game'),
              ),
            if (onAddToStudy != null)
              OutlinedButton(
                onPressed: onAddToStudy,
                child: const Text('Add to study…'),
              ),
            TextButton(onPressed: solitaire.stop, child: const Text('Done')),
          ],
        ),
        if (solitaire.misses.isNotEmpty) ...[
          const SizedBox(height: Space.l),
          Text('Moves you missed', style: text.bodySmall),
          const SizedBox(height: Space.xs),
          for (final miss in solitaire.misses)
            InkWell(
              onTap: () => solitaire.goTo(miss.at),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Text(
                  displaySan(
                    context,
                    miss.tried.isEmpty
                        ? solitaire.moveLabel(miss.at)
                        : '${solitaire.moveLabel(miss.at)}  ·  you tried '
                              '${miss.tried.join(', ')}',
                  ),
                  style: text.bodyMedium,
                ),
              ),
            ),
        ],
      ],
    );
  }
}
