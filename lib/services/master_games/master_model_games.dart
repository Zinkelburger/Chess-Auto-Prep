/// Model-game candidates from the master-games database.
///
/// A scanned PGN database keeps its strongest games in a reservoir and the
/// model-game selector picks from those.  The master database is far too
/// big to reservoir, but its `book` already remembers, per (position, move),
/// the strongest and most recent game that played it — so walking the
/// repertoire and collecting those ids yields exactly the games that follow
/// the repertoire, and nothing else.
library;

import '../../models/build_tree_node.dart';
import '../generation/pgn_freq_map.dart';
import '../generation/pgn_freq_parser.dart'
    show isResultToken, tokenToSan, tokenizeMovetext;
import 'master_games_db.dart';

/// Games from [db] that played the repertoire's moves, as
/// [PgnGameRecord]s for [ModelGameSelector].  Deeper positions are visited
/// first so the cap keeps the games that follow the longest.
///
/// [minElo] drops games whose average rating is below it (0 = keep all).
List<PgnGameRecord> masterGameCandidates(
  MasterGamesDb db,
  BuildTree tree, {
  required bool playAsWhite,
  int minElo = 0,
  int maxGames = 96,
}) {
  // Collect (depth, gameId) over every repertoire move in the tree.
  final byDepth = <int, Set<int>>{};
  void walk(BuildTreeNode node) {
    final isOurTurn = node.isWhiteToMove == playAsWhite;
    for (final child in node.children) {
      if (isOurTurn && !child.isRepertoireMove) continue;
      if (isOurTurn) {
        final List<BookMove> moves;
        try {
          moves = db.bookMoves(node.fen);
        } catch (_) {
          continue;
        }
        for (final m in moves) {
          if (m.uci != child.moveUci) continue;
          final ids = byDepth[node.ply] ??= {};
          // The classical id first: it is the one a reader gets most from,
          // and adding it widens the pool rather than narrowing it.
          if (m.topClassicalGameId != 0) ids.add(m.topClassicalGameId);
          ids.add(m.topGameId);
          ids.add(m.recentGameId);
          break;
        }
      }
      walk(child);
    }
  }

  walk(tree.root);
  if (byDepth.isEmpty) return const [];

  final depths = byDepth.keys.toList()..sort((a, b) => b.compareTo(a));
  final seen = <int>{};
  final out = <PgnGameRecord>[];
  for (final d in depths) {
    for (final id in byDepth[d]!) {
      if (!seen.add(id)) continue;
      final game = db.game(id);
      if (game == null) continue;
      final record = _record(game);
      if (minElo > 0 && record.averageElo < minElo) continue;
      out.add(record);
      if (out.length >= maxGames) return out;
    }
  }
  return out;
}

PgnGameRecord _record(MasterGame g) {
  final sans = <String>[];
  for (final t in tokenizeMovetext(g.movetext)) {
    if (isResultToken(t)) break;
    final san = tokenToSan(t);
    if (san != null) sans.add(san);
    if (sans.length >= PgnGameRecord.maxRetainedPlies) break;
  }
  final where = g.site.trim();
  return PgnGameRecord(
    white: g.white,
    black: g.black,
    whiteElo: g.whiteElo ?? 0,
    blackElo: g.blackElo ?? 0,
    event: where.isEmpty || g.event.contains(where)
        ? g.event
        : '${g.event}, $where',
    date: g.date,
    outcome: GameOutcome.parse(g.result),
    movesSan: sans,
  );
}
