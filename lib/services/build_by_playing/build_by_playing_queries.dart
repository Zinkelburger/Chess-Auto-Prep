part of 'build_by_playing_controller.dart';

/// Read-only chess-position and repertoire-coverage queries.
///
/// These helpers never mutate session state or notify listeners — they only
/// read the repertoire and reason about positions — so they group cleanly
/// apart from the session state machine. Extracted verbatim from
/// [BuildByPlayingController].
mixin _RepertoireQueries on ChangeNotifier {
  RepertoireController get _repertoire;

  /// The repertoire's stored answer for the current position, or null when
  /// this is an uncovered decision point. Prefers the exact-path answer;
  /// falls back to any answer at the same position (transposition), guarded
  /// by SAN legality.
  String? _coveredAnswer(String fen, Position pos) {
    final tree = _repertoire.openingTree;
    if (tree == null) return null;

    OpeningTreeNode? node = tree.root;
    for (final san in _repertoire.currentMoveSequence) {
      node = node!.children[san];
      if (node == null) break;
    }
    if (node != null && node.children.isNotEmpty) {
      final san = _mostPlayedChildSan(node);
      if (san != null && pos.parseSan(san) != null) return san;
    }

    final transposed = tree.fenToNodes[normalizeFen(fen)];
    if (transposed != null) {
      for (final n in transposed) {
        for (final san in n.children.keys) {
          if (pos.parseSan(san) != null) return san;
        }
      }
    }
    return null;
  }

  String? _mostPlayedChildSan(OpeningTreeNode node) {
    String? best;
    var bestGames = -1;
    for (final entry in node.children.entries) {
      if (entry.value.gamesPlayed > bestGames) {
        bestGames = entry.value.gamesPlayed;
        best = entry.key;
      }
    }
    return best;
  }

  /// Split [fullPath] into (prefix already in the repertoire file, remainder)
  /// by walking the opening tree move-by-move. Matches the writer's
  /// exact-mainline chaining semantics.
  (List<String>, List<String>) _splitByCoverage(List<String> fullPath) {
    final tree = _repertoire.openingTree;
    final committed = <String>[];
    var i = 0;
    if (tree != null) {
      OpeningTreeNode? node = tree.root;
      for (; i < fullPath.length; i++) {
        node = node!.children[fullPath[i]];
        if (node == null) break;
        committed.add(fullPath[i]);
      }
    }
    return (committed, fullPath.sublist(i));
  }

  String _fenForSans(List<String> sans) {
    var pos = _positionFromFen(_repertoire.tree.startingFen) ?? Chess.initial;
    for (final san in sans) {
      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);
    }
    return pos.fen;
  }

  Position? _positionFromFen(String fen) {
    try {
      return Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      return null;
    }
  }
}
