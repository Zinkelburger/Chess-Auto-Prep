/// Stored engine suggestions are ordinary PGN RAVs. The best-line token only
/// identifies which path receives analysis styling; it never creates moves.
library;

import 'package:dartchess/dartchess.dart';

import '../../services/pgn_parsing_service.dart' show startPositionFromGame;
import '../../utils/chess_utils.dart' show playSanOrNullMove;
import '../../utils/pgn_comment_utils.dart';

/// Convert legacy/newly generated PV payloads at classified mainline plies to
/// real variations. Consume the payload once, replacing it with a path reference
/// so deleting or editing a stored variation cannot resurrect its old moves.
bool materializeAnalysisVariations(PgnGame game, Set<int> plies) {
  var changed = false;
  var parent = game.moves;
  var pos = startPositionFromGame(game);
  var ply = 0;
  while (parent.children.isNotEmpty) {
    final played = parent.children.first;
    if (plies.contains(ply)) {
      final comments = played.data.comments;
      if (comments != null) {
        for (var i = 0; i < comments.length; i++) {
          final match = pvCommentRe.firstMatch(comments[i]);
          if (match == null) continue;
          // The first engine line is authoritative, matching the eval reader.
          // A stored reference has already been converted; never recreate it.
          if (bestLineCommentRe.hasMatch(match[0]!)) break;
          changed = true;
          final sans = parsePvComment(match[0]!);
          var before = pos;
          var children = parent.children;
          final valid = <String>[];
          for (final san in sans) {
            final after = playSanOrNullMove(before, san);
            if (after == null) break;
            // A suggestion is an alternative to the played move. Even if its
            // first SAN matches, keep the game's actual continuation intact.
            final candidates = valid.isEmpty ? children.skip(1) : children;
            var node = candidates.where((n) => n.data.san == san).firstOrNull;
            if (node == null) {
              node = PgnChildNode(PgnNodeData(san: san));
              children.add(node);
            }
            // The selected engine continuation is the principal path of
            // this analysis RAV; existing alternatives remain siblings.
            if (valid.isNotEmpty && children.first != node) {
              children.remove(node);
              children.insert(0, node);
            }
            valid.add(san);
            children = node.children;
            before = after;
          }
          comments[i] = comments[i]
              .replaceFirst(
                legacyPvCommentRe,
                valid.isEmpty ? '' : '[%bestline ${valid.join(',')}]',
              )
              .trim();
        }
      }
    }
    final next = playSanOrNullMove(pos, played.data.san);
    if (next == null) break;
    pos = next;
    parent = played;
    ply++;
  }
  return changed;
}

/// The path reference used to associate a classified move with its real RAV.
List<String> analysisVariationPath(PgnNodeData move) {
  for (final comment in move.comments ?? const <String>[]) {
    final match = bestLineCommentRe.firstMatch(comment);
    if (match != null) return parsePvComment(match[0]!);
  }
  return const [];
}

/// Remove/shorten path references after an ordinary variation edit. The tree
/// owns the moves; a stale reference must never restore a deleted continuation.
void synchronizeAnalysisVariationPaths(PgnNode<PgnNodeData> tree) {
  var parent = tree;
  while (parent.children.isNotEmpty) {
    final played = parent.children.first;
    final comments = played.data.comments;
    if (comments != null) {
      for (var i = 0; i < comments.length; i++) {
        final match = bestLineCommentRe.firstMatch(comments[i]);
        if (match == null) continue;
        var candidates = parent.children.skip(1);
        final found = <String>[];
        for (final san in parsePvComment(match[0]!)) {
          final node = candidates.where((n) => n.data.san == san).firstOrNull;
          if (node == null) break;
          found.add(san);
          candidates = node.children;
        }
        comments[i] = comments[i]
            .replaceFirst(
              bestLineCommentRe,
              found.isEmpty ? '' : '[%bestline ${found.join(',')}]',
            )
            .trim();
      }
    }
    parent = played;
  }
}
