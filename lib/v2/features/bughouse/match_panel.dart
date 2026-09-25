import 'dart:async';

import 'package:flutter/material.dart';

import '../../chess/bughouse/match.dart';
import '../../chess/bughouse/table.dart';
import '../../ui/confirm_dialog.dart';
import '../../ui/theme.dart';
import 'bughouse_lab.dart';
import 'matches.dart';
import 'new_match_dialog.dart';

/// The lab's matches, where its tables were: `New match` (or the game being
/// played and `Stop`), the history newest first, and the match chosen in
/// it — how White on board 1 scored, its opening, its games. A game clicked
/// goes on the boards; `Follow the game being played` puts the live one
/// there instead.
class MatchPanel extends StatelessWidget {
  const MatchPanel({super.key, required this.matches, required this.lab});

  final Matches matches;
  final BughouseLab lab;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: matches,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final selected = matches.selected;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Head(matches: matches, lab: lab),
            if (matches.problem case final problem?)
              Padding(
                padding: const EdgeInsets.only(top: Space.xs),
                child: Text(
                  _said(problem),
                  style: TextStyle(color: scheme.error),
                ),
              ),
            if (matches.canRetry)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => unawaited(matches.retrySave()),
                  child: const Text('Retry save'),
                ),
              ),
            if (matches.problem is CannotLoad)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => unawaited(matches.load()),
                  child: const Text('Retry'),
                ),
              ),
            const SizedBox(height: Space.s),
            if (matches.matches.isEmpty)
              Text(
                'No matches yet. Set a position up on the boards, then play '
                'it out.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              )
            else ...[
              SizedBox(
                height: labTableRowHeight * 4,
                child: _History(matches: matches),
              ),
              Divider(height: Space.l, color: scheme.outline),
            ],
            if (selected != null)
              Expanded(
                child: _Chosen(matches: matches, match: selected),
              ),
          ],
        );
      },
    );
  }
}

String _said(MatchProblem problem) => switch (problem) {
  NotAPosition() => notAPosition,
  CannotCreate(:final detail) =>
    'Could not create the match directory: $detail',
  CannotLoad(:final detail) => 'Could not read the matches: $detail',
  CannotSave(:final detail) => 'Could not save the match: $detail',
  CannotDelete(:final detail) => 'Could not delete the match: $detail',
  EngineWouldNotStart(:final reason) => reason,
  MatchEngineFailed(:final reason) => 'The match stopped: $reason',
};

class _Head extends StatelessWidget {
  const _Head({required this.matches, required this.lab});

  final Matches matches;
  final BughouseLab lab;

  Future<void> _new(BuildContext context) async {
    final config = await showNewMatchDialog(context, lab);
    if (context.mounted && config != null) unawaited(matches.start(config));
  }

  @override
  Widget build(BuildContext context) {
    final running = matches.running;
    final match = matches.matches.where((m) => m.id == running?.id).firstOrNull;
    if (running == null || match == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
          onPressed: matches.writable ? () => unawaited(_new(context)) : null,
          child: const Text('New match'),
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: Text('Playing game ${running.game} of ${match.config.games}'),
        ),
        if (!matches.following)
          TextButton(
            onPressed: matches.follow,
            child: const Text('Follow the game being played'),
          ),
        const SizedBox(width: Space.s),
        OutlinedButton(onPressed: matches.stop, child: const Text('Stop')),
      ],
    );
  }
}

class _History extends StatelessWidget {
  const _History({required this.matches});

  final Matches matches;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chosen = matches.selected?.id;
    return ListView.builder(
      itemCount: matches.matches.length,
      itemExtent: labTableRowHeight,
      itemBuilder: (context, i) {
        final match = matches.matches[i];
        return InkWell(
          onTap: () => matches.select(match.id),
          child: Container(
            color: match.id == chosen ? scheme.surfaceContainerHighest : null,
            padding: const EdgeInsets.symmetric(horizontal: Space.xs),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    match.config.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${match.openingScore.text} · ${match.status.label}',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The match chosen in the history: its score for White on board 1, its
/// opening, its games.
class _Chosen extends StatelessWidget {
  const _Chosen({required this.matches, required this.match});

  final Matches matches;
  final StoredMatch match;

  String get _score {
    final score = match.openingScore;
    if (score.played == 0) return 'No games yet';
    final share = (100 * score.points / score.played).round();
    final margin = ((score.margin ?? 0) * 100).round();
    return 'White on board 1 scored ${score.text} ($share% ± $margin) · '
        '${score.wins}W ${score.draws}D ${score.losses}L';
  }

  String get _excluded {
    final score = match.openingScore;
    return [
      if (score.unfinished > 0) '${score.unfinished} unfinished, not counted',
      if (score.adjudicated > 0)
        '${score.adjudicated} drawn at the move limit or by both teams sitting',
    ].join(' · ');
  }

  /// The line the match asks about, or where it starts.
  String get _opening {
    final config = match.config;
    if (config.openingLabel.isNotEmpty) return config.openingLabel;
    return config.startDualFen == TablePosition.initial.dualFen
        ? 'From the start'
        : config.startDualFen;
  }

  Future<void> _delete(BuildContext context) async {
    final sure = await confirmAction(
      context,
      title: 'Delete this match?',
      message: '${match.config.name} goes to bughouse_matches/.trash.',
      confirm: 'Delete',
    );
    if (sure) unawaited(matches.delete(match.id));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    final idle = matches.running == null && matches.writable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_score, style: const TextStyle(fontWeight: FontWeight.w600)),
        if (_excluded.isNotEmpty) Text(_excluded, style: muted),
        Row(
          children: [
            Expanded(
              child: Text(
                _opening,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ),
            TextButton(
              onPressed: matches.showOpening,
              child: const Text('Show'),
            ),
            if (idle && match.resumable)
              TextButton(
                onPressed: () => unawaited(matches.resume(match.id)),
                child: const Text('Resume'),
              ),
            if (idle)
              TextButton(
                onPressed: () => unawaited(_delete(context)),
                child: const Text('Delete'),
              ),
          ],
        ),
        Expanded(
          child: _Games(matches: matches, match: match),
        ),
      ],
    );
  }
}

class _Games extends StatelessWidget {
  const _Games({required this.matches, required this.match});

  final Matches matches;
  final StoredMatch match;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: labTableRowHeight,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outline)),
          ),
          child: _cells(
            context,
            '#',
            'White on board 1',
            'Black on board 1',
            'Result',
            muted: true,
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: match.games.length,
            itemExtent: labTableRowHeight,
            itemBuilder: (context, i) {
              final game = match.games[i];
              return InkWell(
                onTap: () => matches.open(game),
                child: Container(
                  color: matches.openGame == game.number
                      ? scheme.surfaceContainerHighest
                      : null,
                  child: _cells(
                    context,
                    '${game.number}',
                    game.whiteName,
                    game.blackName,
                    '${game.result.token} · ${game.ending.label}',
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _cells(
    BuildContext context,
    String number,
    String white,
    String black,
    String result, {
    bool muted = false,
  }) {
    final style = muted
        ? TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)
        : null;
    Widget cell(String text) => Expanded(
      child: Text(
        text,
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      child: Row(
        children: [
          SizedBox(
            width: labMoveNumberWidth,
            child: Text(number, style: style),
          ),
          cell(white),
          cell(black),
          cell(result),
        ],
      ),
    );
  }
}
