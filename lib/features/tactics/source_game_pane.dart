import 'package:flutter/material.dart';

import '../../chess/pgn/move_label.dart';
import '../../chess/tactics/puzzle.dart';
import '../../chess/tactics/source_game.dart';
import '../../ui/theme.dart';
import 'source_games.dart';

/// The Game tab in Tactics: the whole game the puzzle on the board came
/// from, who played it and how it went, the review's counts for it, and its
/// moves with the one the puzzle is about marked and scrolled to.
///
/// The board belongs to the puzzle, so the moves are read here, not
/// played: a move clicked opens the game on an analysis board after it, and
/// Analyze game opens it at the puzzle.
class SourceGamePane extends StatelessWidget {
  const SourceGamePane({
    super.key,
    required this.sources,
    required this.onAnalyze,
  });

  final SourceGames sources;

  /// Opens [puzzle]'s [game] on an analysis board, [ply] moves in.
  final void Function(Puzzle puzzle, PuzzleGame game, int ply) onAnalyze;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sources,
    builder: (context, _) => Padding(
      padding: const EdgeInsets.fromLTRB(
        readingCardInset,
        Space.m,
        readingCardInset,
        Space.s,
      ),
      child: switch (sources.view) {
        NoPuzzleUp() => const _Words('Play a puzzle to see its game.'),
        SourceReading() => const SizedBox.shrink(),
        NoSourceGame() => const _Words('This puzzle has no game.'),
        SourceShown(:final puzzle, :final game, :final counts) => _Shown(
          puzzle: puzzle,
          game: game,
          counts: counts?.words,
          onAnalyze: (ply) => onAnalyze(puzzle, game, ply),
        ),
      },
    ),
  );
}

class _Shown extends StatelessWidget {
  const _Shown({
    required this.puzzle,
    required this.game,
    required this.counts,
    required this.onAnalyze,
  });

  final Puzzle puzzle;
  final PuzzleGame game;
  final String? counts;
  final ValueChanged<int> onAnalyze;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_players(game), style: text.titleMedium),
        Text(
          [game.tag('Result'), game.tag('Date')]
              .where((w) => w.isNotEmpty && w != '*' && w != '????.??.??')
              .join(' · '),
          style: text.bodySmall,
        ),
        if (counts case final counts?) Text(counts, style: text.bodySmall),
        const SizedBox(height: Space.s),
        Expanded(
          child: _Moves(game: game, kind: puzzle.kind, onOpen: onAnalyze),
        ),
        const SizedBox(height: Space.s),
        Align(
          alignment: Alignment.centerLeft,
          child: Tooltip(
            message: 'Open the game on an analysis board at the puzzle',
            child: OutlinedButton(
              onPressed: () => onAnalyze(game.mistake ?? 0),
              child: const Text('Analyze game'),
            ),
          ),
        ),
      ],
    );
  }

  /// `Rival (2105) – Me (2080)`.
  static String _players(PuzzleGame game) {
    String side(String colour) {
      final name = game.tag(colour);
      final elo = game.tag('${colour}Elo');
      return elo.isEmpty ? name : '$name ($elo)';
    }

    return '${side('White')} – ${side('Black')}';
  }
}

/// The game's moves as a book prints them, each one a link; the move the
/// puzzle is about in bold with its mark, brought into view when it comes.
class _Moves extends StatefulWidget {
  const _Moves({required this.game, required this.kind, required this.onOpen});

  final PuzzleGame game;
  final MistakeKind kind;
  final ValueChanged<int> onOpen;

  @override
  State<_Moves> createState() => _MovesState();
}

class _MovesState extends State<_Moves> {
  final _mistake = GlobalKey();

  @override
  void initState() {
    super.initState();
    _reveal();
  }

  @override
  void didUpdateWidget(_Moves old) {
    super.didUpdateWidget(old);
    if (!identical(old.game, widget.game)) _reveal();
  }

  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    final target = _mistake.currentContext;
    if (!mounted || target == null) return;
    Scrollable.ensureVisible(target, alignment: 0.3);
  });

  @override
  Widget build(BuildContext context) {
    final moves = widget.game.moves;
    final mistake = widget.game.mistake;
    return SingleChildScrollView(
      child: Wrap(
        children: [
          for (final (ply, move) in moves.indexed)
            InkWell(
              key: ply == mistake ? _mistake : null,
              onTap: () => widget.onOpen(ply + 1),
              child: Padding(
                padding: moveTokenPadding,
                child: _move(
                  moveNumberLabel(move, startsLine: ply == 0),
                  move.san,
                  marked: ply == mistake,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// A move as the reading card sets one: its number a step quieter, and
  /// the puzzle's move in bold with its mark in the review's colour.
  Widget _move(String number, String san, {required bool marked}) {
    final glyph = widget.kind.glyph;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: number,
            style: const TextStyle(color: readingNumberColor),
          ),
          TextSpan(text: san),
          if (marked)
            TextSpan(
              text: glyph,
              style: TextStyle(color: mistakeColor(glyph)),
            ),
        ],
      ),
      style: marked
          ? readingMoveText.copyWith(fontWeight: FontWeight.w700)
          : readingMoveText,
    );
  }
}

class _Words extends StatelessWidget {
  const _Words(this.words);

  final String words;

  @override
  Widget build(BuildContext context) =>
      Text(words, style: Theme.of(context).textTheme.bodyMedium);
}
