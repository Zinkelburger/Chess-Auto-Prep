import 'dart:convert';

import 'package:crypto/crypto.dart';

/// How a repertoire line gets its id, in one place.
///
/// This was seven methods scattered through `RepertoireService`'s thousand
/// lines — `_fullLineId`, `_generateStableLineId`, `generateLineId`,
/// `_extractLineId`, `lineIdFromHeaders`, `lineIdForGamePgn`, `newLineId` —
/// several of them one-line wrappers over each other. They have no service
/// state at all, and they carry an invariant that spans them: **the id the
/// parser assigns and the id a file edit looks a game up by must be the same
/// rule**, or a rename lands on the wrong game.
///
/// Grouping them makes that invariant reviewable in one screen instead of
/// spread across a file where the collision rule and its two appliers sat
/// four hundred lines apart.
///
/// Ids are persisted: training progress and review history are keyed by
/// them, so changing how any of these compute is a data migration, not a
/// refactor.
class RepertoireLineIds {
  const RepertoireLineIds();

  /// Headers a third-party PGN might carry its own id under, in priority
  /// order. `LineID` is what this app writes.
  static const List<String> headerKeys = [
    'LineID',
    'LineId',
    'Id',
    'Line',
    'Guid',
  ];

  /// The stable move-based id: base64 of the moves and the file position,
  /// truncated to a readable length.
  ///
  /// **Truncation means this is not collision-free.** Two lines sharing a
  /// long opening prefix — the normal case in a repertoire — can produce the
  /// same string, which is exactly why [resolveCollisions] exists. Kept
  /// as-is because it is the id already saved in users' progress files.
  String stable(List<String> moves, int index) {
    final raw = base64Url.encode(utf8.encode('${moves.join(' ')}|$index'));
    final trimmed = raw.replaceAll('=', '');
    return 'line_${trimmed.length > 22 ? trimmed.substring(0, 22) : trimmed}';
  }

  /// A collision-free id: a hash of the whole move list and file position,
  /// so no amount of shared prefix collides.
  String full(List<String> moves, int index) {
    final digest = sha256.convert(utf8.encode('${moves.join(' ')}|$index'));
    return 'line_${digest.toString().substring(0, 22)}';
  }

  /// The id a parsed game resolves to: its own header id when it carries
  /// one, else the [stable] fallback.
  ///
  /// Callers that want to target a specific line ("train this chapter") must
  /// derive the id this way — the header-blind [stable] silently mismatches
  /// any PGN that carries such a header.
  String fromHeaders(
    Map<String, String> headers,
    List<String> moves,
    int index,
  ) {
    for (final key in headerKeys) {
      final value = headers[key];
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }
    return stable(moves, index);
  }

  /// The id a line appended at file position [index] will resolve to once
  /// the file is re-parsed, given the ids already in the file.
  ///
  /// Deliberately **not** the same opening move as [resolveCollision]: a new
  /// line has no header id yet, so the id it will actually get on reload is
  /// the [stable] one. This predicts that, and only escalates when the
  /// prediction is already taken. Reversing the two would hand new lines a
  /// hash id that a reload then disagrees with.
  String forNewLine(
    List<String> moves,
    int index, {
    required Iterable<String> existingIds,
  }) {
    final seen = existingIds.toSet();
    final predicted = stable(moves, index);
    if (seen.add(predicted)) return predicted;
    return resolveCollision(moves, index, seen);
  }

  /// The replacement id for a line whose id is already taken, added to
  /// [seen] (which this mutates).
  ///
  /// Escalates straight to [full] rather than trying [stable] first, because
  /// the colliding id may be a *header* id — in which case [stable] has not
  /// been tried and could be free, and returning it would give the line a
  /// different id than the one already saved against it.
  ///
  /// The loop is astronomically unlikely to run — it is a 22-character
  /// SHA-256 prefix — but the invariant is absolute: a silent duplicate
  /// mixes two lines' training histories and lets a delete land on the wrong
  /// game.
  String resolveCollision(List<String> moves, int index, Set<String> seen) {
    var id = full(moves, index);
    while (!seen.add(id)) {
      id = full([...moves, id], index);
    }
    return id;
  }

  /// Rewrites [ids] so every entry is distinct: the first claimant of an id
  /// keeps it, every later collision is re-derived through [resolveCollision].
  ///
  /// Keeping the first claimant is what makes ids already present in saved
  /// progress stay valid. Returns a list the same length as [ids]; entries
  /// that were null stay null.
  ///
  /// This is the single definition of the rule that both
  /// `RepertoireService.parseRepertoirePgn` (over parsed lines) and
  /// `lineIdsForGames` (over raw game text, for file edits) must follow. They
  /// implemented it separately, and a divergence between them means an edit
  /// lands on a different game than the one the user clicked.
  List<String?> resolveCollisions(
    List<String?> ids,
    List<List<String>> moves,
    List<int> indices,
  ) {
    final seen = <String>{};
    final out = <String?>[];
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      if (id == null) {
        out.add(null);
        continue;
      }
      out.add(seen.add(id) ? id : resolveCollision(moves[i], indices[i], seen));
    }
    return out;
  }
}

/// The shared instance. Const, because none of this holds state.
const RepertoireLineIds repertoireLineIds = RepertoireLineIds();
