import 'package:flutter/material.dart';

import '../../chess/pv_text.dart';
import '../../ui/theme.dart';
import '../../workspace/document_session.dart';
import 'player_analysis.dart';

/// The selected player's opening tree follows the same board as the moves and
/// engine. Clicking a continuation uses the workspace's held analysis edits.
class PlayerTreePane extends StatelessWidget {
  const PlayerTreePane({
    super.key,
    required this.analysis,
    required this.session,
    required this.onOpen,
  });
  final PlayerAnalysis analysis;
  final DocumentSession session;
  final ValueChanged<int> onOpen;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([analysis, session.anyChange]),
    builder: (context, _) {
      final corpus = analysis.corpus;
      if (corpus == null)
        return const Center(
          child: Text('Choose a player and add their games.'),
        );
      final answer = corpus.openings.answer(
        session.fen,
        keeps: (i) => analysis.includes(corpus.games[i]),
      );
      if (answer.moves.isEmpty)
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(Space.l),
            child: Text(
              'No saved games continue from this position. Go back along the line or choose another position.',
            ),
          ),
        );
      final total = answer.moves.fold<int>(0, (n, m) => n + m.games);
      return ListView(
        padding: const EdgeInsets.all(Space.m),
        children: [
          Text(
            '${analysis.player!.name} as ${analysis.side.name == 'white' ? 'White' : 'Black'} · $total ${total == 1 ? 'game' : 'games'}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final move in answer.moves)
            ListTile(
              dense: true,
              title: Text(pvText(session.fen, [move.uci])),
              trailing: Text(
                '${move.games} · ${(100 * move.games / total).round()}%',
              ),
              subtitle: Text(
                '${move.white} White wins · ${move.draws} draws · ${move.black} Black wins${move.undecided > 0 ? ' · ${move.undecided} unfinished' : ''}',
              ),
              onTap: () => session.playMove(move.uci),
            ),
          const Divider(),
          Text(
            'Games at this position',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final game in answer.games)
            ListTile(
              title: Text('${game.white} – ${game.black}'),
              subtitle: Text('${game.result} · ${game.year ?? ''}'),
              onTap: () {
                final index = int.tryParse(game.id);
                if (index != null) onOpen(index);
              },
            ),
        ],
      );
    },
  );
}
