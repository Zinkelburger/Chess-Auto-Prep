/// Choosing model games from the user's game database.
///
/// A course chapter of variations tells you what to play; a model game tells
/// you what you are playing *for*.  This picks games that actually walk out of
/// the repertoire — every one of our moves is the move the repertoire teaches
/// — and then prefers the ones a strong player would learn the most from.
///
/// Pure over the built tree and the parsed database: no engine, no I/O.
library;

import '../../../models/build_tree_node.dart';
import '../fen_map.dart';
import '../pgn_freq_map.dart';

/// A database game that follows the repertoire, with the evidence for why it
/// was chosen.
class ModelGame {
  final PgnGameRecord record;

  /// Plies the game stayed inside the repertoire, counted from the build
  /// root.  Our moves had to match the selected repertoire move; the
  /// opponent's only had to exist in the tree.
  final int followedPlies;

  const ModelGame({required this.record, required this.followedPlies});

  /// Moves the game shares with the repertoire — its "line signature", used
  /// to keep the selection from being six games of the same variation.
  List<String> get followedMoves =>
      record.movesSan.take(followedPlies).toList(growable: false);
}

/// Ranks and picks model games.
class ModelGameSelector {
  const ModelGameSelector({
    required this.playAsWhite,
    this.minFollowedPlies = 6,
    this.signatureDepth = 10,
  });

  final bool playAsWhite;

  /// A game that leaves the repertoire almost immediately illustrates nothing
  /// about it.
  final int minFollowedPlies;

  /// Two games count as showing the same variation when they agree with the
  /// repertoire for this many plies.
  final int signatureDepth;

  /// Select up to [limit] games, most instructive first.
  ///
  /// Variety comes before rank: one game per distinct variation is taken
  /// before any variation gets a second, so a course covers its chapters
  /// instead of showing six wins in the same line.
  List<ModelGame> select(
    PgnFreqMap database,
    BuildTree tree, {
    required int limit,
    FenMap? fenMap,
  }) {
    if (limit <= 0 || database.games.isEmpty) return const [];

    final candidates = <ModelGame>[];
    for (final record in database.games.entries) {
      final followed = _followedPlies(tree, record.movesSan, fenMap);
      if (followed < minFollowedPlies) continue;
      candidates.add(ModelGame(record: record, followedPlies: followed));
    }
    if (candidates.isEmpty) return const [];

    candidates.sort(_byInstructiveness);

    // Round-robin over variations: pass one takes the best game of each,
    // pass two the next best, and so on until the limit is reached.
    final byVariation = <String, List<ModelGame>>{};
    for (final game in candidates) {
      (byVariation[_signature(game)] ??= []).add(game);
    }

    final selected = <ModelGame>[];
    for (var round = 0; selected.length < limit; round++) {
      var added = false;
      for (final games in byVariation.values) {
        if (round >= games.length) continue;
        selected.add(games[round]);
        added = true;
        if (selected.length >= limit) break;
      }
      if (!added) break;
    }

    selected.sort(_byInstructiveness);
    return selected;
  }

  String _signature(ModelGame game) => game.record.movesSan
      .take(
        game.followedPlies < signatureDepth
            ? game.followedPlies
            : signatureDepth,
      )
      .join(' ');

  /// Deeper first, then by how much a reader learns from the result, then by
  /// player strength.  A win by our side is the ideal illustration; a draw
  /// still shows the plan; a loss shows the repertoire failing and is kept
  /// only as a last resort.
  int _byInstructiveness(ModelGame a, ModelGame b) {
    final depth = b.followedPlies.compareTo(a.followedPlies);
    if (depth != 0) return depth;
    final result = _resultRank(b.record).compareTo(_resultRank(a.record));
    if (result != 0) return result;
    return b.record.averageElo.compareTo(a.record.averageElo);
  }

  int _resultRank(PgnGameRecord record) {
    if (record.wonBy(asWhite: playAsWhite)) return 2;
    if (!record.isDecisive) return 1;
    return 0;
  }

  /// How far [movesSan] stays inside the repertoire, starting at the tree
  /// root.  Stops at the first move that is not in the tree, or at the first
  /// of *our* moves that is not the one the repertoire selected.
  int _followedPlies(BuildTree tree, List<String> movesSan, FenMap? fenMap) {
    var node = tree.root;
    var followed = 0;

    for (final san in movesSan) {
      final resolved = resolveTransposition(node, fenMap);
      final isOurTurn = resolved.isWhiteToMove == playAsWhite;

      BuildTreeNode? next;
      for (final child in resolved.children) {
        if (child.moveSan == san) {
          next = child;
          break;
        }
      }
      if (next == null) break;
      if (isOurTurn && !next.isRepertoireMove) break;

      node = next;
      followed++;
    }
    return followed;
  }
}
