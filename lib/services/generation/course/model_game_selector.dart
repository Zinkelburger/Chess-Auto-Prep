/// Choosing model games from the user's game database.
///
/// A course chapter of variations tells you what to play; a model game tells
/// you what you are playing *for*.  This picks games that actually walk out of
/// the repertoire — every one of our moves is the move the repertoire teaches
/// — and then prefers the ones a strong player would learn the most from.
///
/// Pure over the built tree and the candidate games (a scanned PGN
/// database's reservoir, or games pulled from the master-games database):
/// no engine, no I/O.
library;

import '../../../models/build_tree_node.dart';
import '../fen_map.dart';
import '../pgn_freq_map.dart';

/// Who stepped off the repertoire first in a model game.
enum DepartureKind {
  /// Our side played something other than the repertoire move — the
  /// repertoire *improves on* (or at least differs from) the game here.
  ours,

  /// The opponent played a reply the repertoire does not cover.
  opponent,
}

/// Where a model game leaves the repertoire, and what the repertoire does
/// there instead — what an annotated model game needs to say "we play
/// 10...Qb6 here".  Absent when the game ends, or the tree runs out, while
/// still inside the repertoire.
class ModelGameDeparture {
  /// Index in the game's `movesSan` of the departing move.
  final int index;
  final DepartureKind kind;

  /// Position the departing move was played from (the tree node's FEN).
  final String fenBefore;

  /// The move the game played.
  final String gameSan;

  /// [DepartureKind.ours]: the repertoire move followed by its mainline, as
  /// SAN from [fenBefore] — a clickable variation.  Empty otherwise.
  final List<String> repertoireLine;

  /// [DepartureKind.opponent]: the replies the repertoire does prepare from
  /// [fenBefore], most likely first.  Empty otherwise.
  final List<String> preparedReplies;

  const ModelGameDeparture({
    required this.index,
    required this.kind,
    required this.fenBefore,
    required this.gameSan,
    this.repertoireLine = const [],
    this.preparedReplies = const [],
  });

  String? get repertoireSan =>
      repertoireLine.isEmpty ? null : repertoireLine.first;
}

/// A database game that follows the repertoire, with the evidence for why it
/// was chosen.
class ModelGame {
  final PgnGameRecord record;

  /// Plies the game stayed inside the repertoire, counted from the build
  /// root.  Our moves had to match the selected repertoire move; the
  /// opponent's only had to exist in the tree.
  final int followedPlies;

  /// Where and how the game left the repertoire (null: it never did within
  /// the tree's reach).
  final ModelGameDeparture? departure;

  const ModelGame({
    required this.record,
    required this.followedPlies,
    this.departure,
  });

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
  /// [improvedFens] are the positions where the repertoire was shown to beat
  /// master practice (`MasterImprovement` keys).  A game we improve on
  /// departs at exactly that position, and departing early is what
  /// [_byInstructiveness] ranks *down* — so without a reserved share these
  /// games lose every slot to games that follow further, and the course
  /// cites "improves on Kasparov–Karpov" while never showing the reader what
  /// Kasparov–Karpov actually did.  Half the slots (at least one) are held
  /// for them when any exist.
  List<ModelGame> select(
    Iterable<PgnGameRecord> games,
    BuildTree tree, {
    required int limit,
    FenMap? fenMap,
    Set<String> improvedFens = const {},
  }) {
    if (limit <= 0) return const [];

    final candidates = <ModelGame>[];
    for (final record in games) {
      final (followed, departure) = _follow(tree, record.movesSan, fenMap);
      if (followed < minFollowedPlies) continue;
      candidates.add(
        ModelGame(
          record: record,
          followedPlies: followed,
          departure: departure,
        ),
      );
    }
    if (candidates.isEmpty) return const [];

    candidates.sort(_byInstructiveness);

    // Reserved share first: the best games we demonstrably improve on.
    final selected = <ModelGame>[];
    if (improvedFens.isNotEmpty) {
      final improved = [
        for (final g in candidates)
          if (g.departure != null &&
              g.departure!.kind == DepartureKind.ours &&
              improvedFens.contains(g.departure!.fenBefore))
            g,
      ];
      final reserve = limit ~/ 2 < 1 ? 1 : limit ~/ 2;
      for (final g in improved) {
        if (selected.length >= reserve || selected.length >= limit) break;
        selected.add(g);
      }
      candidates.removeWhere(selected.contains);
    }

    // Round-robin over variations: pass one takes the best game of each,
    // pass two the next best, and so on until the limit is reached.
    final byVariation = <String, List<ModelGame>>{};
    for (final game in candidates) {
      (byVariation[_signature(game)] ??= []).add(game);
    }

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

  /// Plies of the repertoire mainline shown after a departure, counting the
  /// repertoire move itself.
  static const int repertoireLinePlies = 10;

  /// Prepared replies listed at an opponent departure.
  static const int preparedRepliesShown = 3;

  /// How far [movesSan] stays inside the repertoire, starting at the tree
  /// root, and where it leaves.  Following stops at the first move that is
  /// not in the tree, or at the first of *our* moves that is not the one the
  /// repertoire selected; the departure describes that move when the tree
  /// still had something to say there.
  (int, ModelGameDeparture?) _follow(
    BuildTree tree,
    List<String> movesSan,
    FenMap? fenMap,
  ) {
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
      final stays = next != null && (!isOurTurn || next.isRepertoireMove);
      if (!stays) {
        return (followed, _departure(resolved, followed, san, fenMap));
      }
      node = next;
      followed++;
    }
    return (followed, null);
  }

  ModelGameDeparture? _departure(
    BuildTreeNode node,
    int index,
    String gameSan,
    FenMap? fenMap,
  ) {
    final isOurTurn = node.isWhiteToMove == playAsWhite;
    if (isOurTurn) {
      final line = _repertoireLine(node, fenMap);
      if (line.isEmpty) return null; // tree ends here: nothing to compare
      return ModelGameDeparture(
        index: index,
        kind: DepartureKind.ours,
        fenBefore: node.fen,
        gameSan: gameSan,
        repertoireLine: line,
      );
    }
    final replies = node.children.toList()
      ..sort((a, b) => b.moveProbability.compareTo(a.moveProbability));
    if (replies.isEmpty) return null;
    return ModelGameDeparture(
      index: index,
      kind: DepartureKind.opponent,
      fenBefore: node.fen,
      gameSan: gameSan,
      preparedReplies: [
        for (final c in replies.take(preparedRepliesShown)) c.moveSan,
      ],
    );
  }

  /// The repertoire mainline from an our-move [node]: our selected move at
  /// our turns, the most likely reply at theirs, for [repertoireLinePlies].
  List<String> _repertoireLine(BuildTreeNode node, FenMap? fenMap) {
    final out = <String>[];
    var current = node;
    final visited = <String>{};
    while (out.length < repertoireLinePlies) {
      final resolved = resolveTransposition(current, fenMap);
      if (!visited.add(resolved.fen)) break;
      final isOurTurn = resolved.isWhiteToMove == playAsWhite;
      BuildTreeNode? next;
      if (isOurTurn) {
        for (final c in resolved.children) {
          if (c.isRepertoireMove) {
            next = c;
            break;
          }
        }
      } else {
        for (final c in resolved.children) {
          if (next == null || c.moveProbability > next.moveProbability) {
            next = c;
          }
        }
      }
      if (next == null) break;
      out.add(next.moveSan);
      current = next;
    }
    return out;
  }
}
