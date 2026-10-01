import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/explorer_answer.dart';
import '../../chess/pv_text.dart';
import '../../ui/move_notation.dart';
import '../../ui/theme.dart';
import '../../workspace/document_session.dart';
import '../../workspace/explorer_pane.dart' show ResultBar;
import 'analysis_rows.dart';
import 'player_analysis.dart';

/// The Player openings tab: what the chosen player's games did from the
/// position on the board, as the Explorer tab draws a database — a row per
/// move with its games and how they ended — then the games themselves.
///
/// It follows the same board as the moves and the engine. A move clicked is
/// played on it, in the workspace's held analysis edits; a game clicked
/// opens at this position.
class PlayerTreePane extends StatelessWidget {
  const PlayerTreePane({
    super.key,
    required this.analysis,
    required this.session,
    required this.onOpen,
    required this.onStart,
  });
  final PlayerAnalysis analysis;
  final DocumentSession session;
  final ValueChanged<int> onOpen;

  /// Puts the player's games on the board from their first move: the way
  /// out of a position none of them reached.
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([analysis, session.anyChange]),
    builder: (context, _) {
      final corpus = analysis.corpus;
      if (corpus == null) {
        return const ListMessage('Choose a player to see what they play.');
      }
      final answer = corpus.openings.answer(
        session.fen,
        keeps: (i) => analysis.includes(corpus.games[i]),
      );
      if (answer.moves.isEmpty) return _offBook();
      final total = answer.moves.fold<int>(0, (n, m) => n + m.games);
      final side = analysis.side == Side.white ? 'White' : 'Black';
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, 0),
            child: Text(
              '${analysis.player!.name} as $side · '
              '$total ${total == 1 ? 'game' : 'games'}',
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const _TableHeader(),
          for (final move in answer.moves)
            _MoveRow(
              move: move,
              // The index counts moves by their squares; the board names them.
              san: pvMoves(session.fen, [move.uci]).firstOrNull?.san ?? '',
              total: total,
              onTap: () => session.playMove(move.uci),
            ),
          const _Heading('Games'),
          for (final game in answer.games)
            _GameRow(
              game: game,
              onTap: () {
                final index = int.tryParse(game.id);
                if (index != null) onOpen(index);
              },
            ),
        ],
      );
    },
  );

  /// The board is somewhere the player's games never were, as it is when
  /// the mode is entered from another one.
  Widget _offBook() => ListMessage(
    analysis.gameIndexes.isEmpty
        ? 'No games match. Try the other colour or loosen the filters.'
        : 'None of these games reached the position on the board.',
    action: analysis.gameIndexes.isEmpty
        ? null
        : OutlinedButton(
            onPressed: onStart,
            child: const Text('Go to the first move'),
          ),
  );
}

/// The column names over the rows, in the Explorer table's own widths.
class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return SizedBox(
      height: explorerHeaderHeight + Space.s,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          height: explorerHeaderHeight,
          child: Row(
            children: [
              const SizedBox(width: Space.m),
              SizedBox(
                width: explorerMoveWidth,
                child: Text('Move', style: style),
              ),
              SizedBox(
                width: explorerGamesWidth,
                child: Text('Games', style: style, textAlign: TextAlign.right),
              ),
              const SizedBox(width: Space.m),
              Expanded(child: Text('White / Draw / Black', style: style)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One move the player's games went on with: the move, in how many games
/// and what share of them, and how those games ended.
class _MoveRow extends StatelessWidget {
  const _MoveRow({
    required this.move,
    required this.san,
    required this.total,
    required this.onTap,
  });

  final ExplorerMove move;
  final String san;
  final int total;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final share = total == 0 ? 0 : (100 * move.games / total).round();
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: replyRowHeight,
        child: Row(
          children: [
            const SizedBox(width: Space.m),
            SizedBox(
              width: explorerMoveWidth,
              child: Text(
                displaySan(context, san),
                style: monoText.copyWith(color: scheme.onSurface),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(
              width: explorerGamesWidth,
              child: Text(
                '${move.games} · $share%',
                textAlign: TextAlign.right,
                style: monoText.copyWith(color: scheme.onSurfaceVariant),
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
                  child: ResultBar(
                    white: move.white,
                    draws: move.draws,
                    black: move.black,
                  ),
                ),
              ),
            ),
            const SizedBox(width: Space.m),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.words);

  final String words;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.m, Space.l, Space.m, Space.xs),
    child: Text(words, style: Theme.of(context).textTheme.labelSmall),
  );
}

/// One game that reached the position: the players, how it ended and when.
class _GameRow extends StatelessWidget {
  const _GameRow({required this.game, required this.onTap});

  final ExplorerGame game;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: listRowHeight,
        child: Row(
          children: [
            const SizedBox(width: Space.m),
            Expanded(
              child: Text(
                '${game.white} – ${game.black}',
                style: muted?.copyWith(color: theme.colorScheme.onSurface),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: Space.m),
            Text(
              game.result,
              style: monoText.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: Space.m),
            SizedBox(
              width: explorerGamesWidth / 2,
              child: Text(
                '${game.year ?? ''}',
                style: muted,
                textAlign: TextAlign.right,
              ),
            ),
            const SizedBox(width: Space.m),
          ],
        ),
      ),
    );
  }
}
