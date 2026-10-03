import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
          'Good alternatives count. Play follows the original game.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: Space.s),
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
        const SizedBox(height: Space.s),
        _Row(
          label: 'Start at',
          child: SegmentedButton<bool>(
            key: const ValueKey('solitaire-start'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: true, label: Text('Beginning')),
              ButtonSegment(value: false, label: Text('Current position')),
            ],
            selected: {solitaire.fromStart},
            onSelectionChanged: (value) => solitaire.setFromStart(value.first),
          ),
        ),
        const SizedBox(height: Space.s),
        Text(
          count == 1
              ? '1 $side move to guess.'
              : '$count $side moves to guess.',
          style: text.bodySmall,
        ),
        const SizedBox(height: Space.s),
        if (!solitaire.fromStart) ...[
          Text(
            'Follows the main line; variations start at their branch point.',
            style: text.bodySmall,
          ),
          const SizedBox(height: Space.s),
        ],
        if (solitaire.problem case final problem?) ...[
          Text(problem, style: text.bodyMedium),
          const SizedBox(height: Space.s),
        ],
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
        Text(
          solitaire.waitingForReply
              ? 'Opponent replying…'
              : solitaire.checking
              ? 'Checking your move…'
              : 'Find $side’s move',
          style: text.titleMedium,
        ),
        const SizedBox(height: Space.s),
        Semantics(
          liveRegion: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (solitaire.betterMove) const _Crown(label: 'Better move!'),
                Text(
                  displaySan(context, feedback ?? ''),
                  style: text.bodyMedium?.copyWith(
                    color: solitaire.lastWrong ? scheme.error : null,
                  ),
                ),
                if (solitaire.hint case final hint?)
                  Text(displaySan(context, hint), style: text.bodyMedium),
              ],
            ),
          ),
        ),
        if (solitaire.problem case final problem?)
          Text(problem, style: text.bodySmall),
        if (!solitaire.atCurrentMove)
          TextButton(
            onPressed: solitaire.returnToGuess,
            child: const Text('Return to current move'),
          ),
        const SizedBox(height: Space.m),
        _actions(context),
        const SizedBox(height: Space.l),
        Text(
          '${solitaire.guessed} of ${solitaire.total} completed · '
          '${solitaire.firstTry} unaided · ${solitaire.revealed} revealed',
          style: text.bodySmall,
        ),
        if (solitaire.preparing && !solitaire.checking)
          Text('Preparing move check…', style: text.bodySmall),
      ],
    );
  }

  Widget _actions(BuildContext context) => Wrap(
    spacing: Space.s,
    runSpacing: Space.s,
    children: [
      Tooltip(
        message:
            'Names the piece played in the game. '
            'This move will count as assisted.',
        child: OutlinedButton.icon(
          key: const ValueKey('solitaire-hint'),
          onPressed: solitaire.canHint ? solitaire.showHint : null,
          icon: const Icon(Icons.lightbulb_outline),
          label: const Text('Hint'),
        ),
      ),
      OutlinedButton.icon(
        key: const ValueKey('solitaire-reveal'),
        onPressed: solitaire.canReveal ? solitaire.reveal : null,
        icon: const Icon(Icons.visibility_outlined),
        label: const Text('Give up this move'),
      ),
      Tooltip(
        message: AppKey.leave.tip('Stop solitaire'),
        child: TextButton(onPressed: solitaire.stop, child: const Text('Stop')),
      ),
    ],
  );
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
      '${solitaire.accepted}/${solitaire.guessed} solved',
      '${solitaire.firstTry} unaided',
      if (solitaire.hinted > 0) '${solitaire.hinted} hinted',
      if (solitaire.revealed > 0) '${solitaire.revealed} shown',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            'Complete — ${parts.join(', ')}',
            style: text.titleMedium,
          ),
        ),
        if (solitaire.crowns > 0) ...[
          const SizedBox(height: Space.s),
          _Crown(
            label:
                '${solitaire.crowns} better '
                '${solitaire.crowns == 1 ? 'move' : 'moves'} found',
          ),
        ],
        const SizedBox(height: Space.s),
        Text(
          'The full game above includes your attempts and assistance. '
          'Select a move to review it on the board.',
          style: text.bodySmall,
        ),
        const SizedBox(height: Space.m),
        _actions(context),
        if (solitaire.misses.isNotEmpty) ...[
          const SizedBox(height: Space.l),
          Text('Review assisted moves and retries', style: text.bodySmall),
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
                  style: readingMoveText,
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _actions(BuildContext context) => Wrap(
    spacing: Space.s,
    runSpacing: Space.s,
    children: [
      FilledButton.icon(
        key: const ValueKey('solitaire-copy-pgn'),
        onPressed: () async {
          final pgn = solitaire.reviewPgn;
          if (pgn == null) return;
          await Clipboard.setData(ClipboardData(text: pgn));
          if (context.mounted)
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(content: Text('Session PGN copied')),
            );
        },
        icon: const Icon(Icons.copy_outlined),
        label: const Text('Copy session PGN'),
      ),
      OutlinedButton(
        onPressed: solitaire.again,
        child: const Text('Play again'),
      ),
      if (onNextGame != null)
        OutlinedButton(onPressed: onNextGame, child: const Text('Next game')),
      if (onAddToStudy != null)
        OutlinedButton(
          onPressed: onAddToStudy,
          child: const Text('Add to study…'),
        ),
      TextButton(onPressed: solitaire.stop, child: const Text('Done')),
    ],
  );
}

class _Crown extends StatelessWidget {
  const _Crown({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(
        Icons.emoji_events_outlined,
        size: IconSize.menu,
        color: Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(width: Space.s),
      Flexible(
        child: Text(label, style: Theme.of(context).textTheme.titleSmall),
      ),
    ],
  );
}
