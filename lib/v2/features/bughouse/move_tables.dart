import 'package:flutter/material.dart';

import '../../chess/bughouse/table.dart';
import '../../storage/bughouse_books.dart';
import '../../ui/theme.dart';
import '../../workspace/explorer_pane.dart' show ResultBar;
import 'archive_moves.dart';
import 'bughouse_lab.dart';
import 'table_search.dart';

/// Each board's legal moves with their scores for the chosen clock, a
/// plain rule between the two. A table is headed by who is on move there
/// and reads its scores from that player's side, best first; a move not
/// scored reads `—`. Pointing at a row draws the move on its board;
/// clicking plays it.
class MoveTables extends StatelessWidget {
  const MoveTables({super.key, required this.lab, required this.scores});

  final BughouseLab lab;
  final TableScores scores;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _MoveTable(
            key: const ValueKey(('moves', BoardNumber.one)),
            lab: lab,
            board: BoardNumber.one,
            scores: scores,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.m),
          child: VerticalDivider(width: 1, color: scheme.outline),
        ),
        Expanded(
          child: _MoveTable(
            key: const ValueKey(('moves', BoardNumber.two)),
            lab: lab,
            board: BoardNumber.two,
            scores: scores,
          ),
        ),
      ],
    );
  }
}

class _MoveTable extends StatelessWidget {
  const _MoveTable({
    super.key,
    required this.lab,
    required this.board,
    required this.scores,
  });

  final BughouseLab lab;
  final BoardNumber board;
  final TableScores scores;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final position = lab.position;
    final rows = tableRows(position, board, scores.scores);
    final scored = rows.isNotEmpty && !rows.first.score.isEmpty;
    final head = TextStyle(color: scheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(board.label, style: const TextStyle(fontWeight: FontWeight.w600)),
        Container(
          height: labTableRowHeight,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outline)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Move: Player ${position.mover(board).letter}',
                  style: TextStyle(color: scheme.onSurface),
                ),
              ),
              Tooltip(
                message:
                    'Hivemind’s scale, not pawns: 0.00 is level, + is good '
                    'for the player on move',
                child: SizedBox(
                  width: labScoreWidth,
                  child: Text('Score', style: head, textAlign: TextAlign.right),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemExtent: labTableRowHeight,
            itemBuilder: (context, i) =>
                _MoveRow(lab: lab, row: rows[i], best: scored && i == 0),
          ),
        ),
      ],
    );
  }
}

class _MoveRow extends StatelessWidget {
  const _MoveRow({required this.lab, required this.row, required this.best});

  final BughouseLab lab;
  final ScoredMove row;
  final bool best;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final move = row.move;
    final weight = best ? FontWeight.w600 : null;
    return _Pointable(
      lab: lab,
      pointed: {move.board: move.uci},
      onTap: () => lab.play(move.board, move.uci),
      child: Row(
        children: [
          Expanded(
            child: Text(move.san, style: monoText.copyWith(fontWeight: weight)),
          ),
          Tooltip(
            message: row.pv,
            waitDuration: previewDelay,
            child: SizedBox(
              width: labScoreWidth,
              child: Text(
                row.score.text,
                textAlign: TextAlign.right,
                style: monoText.copyWith(
                  color: row.score.isEmpty ? scheme.onSurfaceVariant : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A row that draws [pointed] on the boards while the pointer is on it and
/// takes it away when it leaves.
class _Pointable extends StatelessWidget {
  const _Pointable({
    required this.lab,
    required this.pointed,
    required this.onTap,
    required this.child,
  });

  final BughouseLab lab;
  final LabPreview pointed;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => lab.preview.value = pointed,
    onExit: (_) => lab.preview.value = null,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xs),
        child: child,
      ),
    ),
  );
}

/// What the FICS archive recorded from the table on screen: each
/// continuation, most played first, with how many games and how they went
/// for our team, won, drawn and lost.
class ArchiveBlock extends StatelessWidget {
  const ArchiveBlock({super.key, required this.lab, required this.archive});

  final BughouseLab lab;
  final ArchiveMoves archive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: Space.s),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outline)),
      ),
      child: switch (archive.lookup) {
        null => const SizedBox.shrink(),
        FicsAbsent() => _say(
          context,
          'No FICS bughouse database on this machine.',
        ),
        FicsUnreadable(:final detail) => _say(
          context,
          'The FICS archive could not be read: $detail',
        ),
        FicsFound(:final archive, :final position) => _found(
          context,
          archive,
          position,
        ),
      },
    );
  }

  Widget _say(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: Space.s),
    child: Text(
      text,
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );

  Widget _found(
    BuildContext context,
    FicsArchive archive,
    FicsPosition position,
  ) {
    final moves = position.moves.take(12).toList();
    final heading =
        'FICS archive · ${position.games} games here · ${archive.years}';
    if (moves.isEmpty) {
      return _say(context, '$heading\n${_empty(archive, position)}');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.xs),
          child: Text(
            heading,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: moves.length,
            itemExtent: labTableRowHeight,
            itemBuilder: (context, i) => _ArchiveRow(lab: lab, move: moves[i]),
          ),
        ),
      ],
    );
  }

  String _empty(FicsArchive archive, FicsPosition position) {
    if (position.games > 0) {
      return 'No continuations meet the archive minimum of '
          '${archive.minGames} games, or this is the end of the indexed line.';
    }
    final plies = lab.line.applied.length;
    if (identical(lab.line.root, TablePosition.initial) &&
        plies > archive.maxPly) {
      return 'Past the archive, which is indexed to ${archive.maxPly} plies.';
    }
    return 'No archived game reached this position.';
  }
}

class _ArchiveRow extends StatelessWidget {
  const _ArchiveRow({required this.lab, required this.move});

  final BughouseLab lab;
  final FicsMove move;

  @override
  Widget build(BuildContext context) {
    final position = lab.position;
    final seat = Seat.of(move.board, move.mover);
    final uci = position.moveBySan(move.board, move.san)?.uci;
    final ours = lab.team == Team.ab;
    final won = ours ? move.abWins : move.cdWins;
    final lost = ours ? move.cdWins : move.abWins;
    return Tooltip(
      message: move.averageElo == null
          ? '${move.unknown} unfinished'
          : 'Average rating ${move.averageElo} · ${move.unknown} unfinished',
      waitDuration: previewDelay,
      child: _Pointable(
        lab: lab,
        pointed: {move.board: ?uci},
        onTap: () {
          if (uci != null) lab.play(move.board, uci);
        },
        child: Row(
          children: [
            SizedBox(
              width: labLabelWidth,
              child: Text('${seat.letter} ${move.san}', style: monoText),
            ),
            SizedBox(
              width: labScoreWidth,
              child: Text(
                '${move.games}',
                style: monoText,
                textAlign: TextAlign.right,
              ),
            ),
            const SizedBox(width: Space.m),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: explorerBarMaxWidth,
                  ),
                  child: ResultBar(white: won, draws: move.draws, black: lost),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
