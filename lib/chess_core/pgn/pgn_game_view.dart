import 'package:dartchess/dartchess.dart';

/// Detached game-level values; the parsed mutable tree is never published.
final class PgnGameMetadata {
  PgnGameMetadata.capture(PgnGame game)
    : headers = Map.unmodifiable(game.headers),
      comments = List.unmodifiable(game.comments);

  final Map<String, String> headers;
  final List<String> comments;
}

/// One immutable revision of a PGN move's annotations.
///
/// [identity] is opaque and stable across revisions of the same owned move.
/// It lets delayed commands reject a move from a replaced game.
final class PgnMoveSnapshot {
  PgnMoveSnapshot.capture(PgnNodeData data, {Object? identity})
    : identity = identity ?? Object(),
      san = data.san,
      comments = data.comments == null
          ? null
          : List.unmodifiable(data.comments!),
      startingComments = data.startingComments == null
          ? null
          : List.unmodifiable(data.startingComments!),
      nags = data.nags == null ? null : List.unmodifiable(data.nags!);

  final Object identity;
  final String san;
  final List<String>? comments;
  final List<String>? startingComments;
  final List<int>? nags;

  /// A new mutable codec value, detached from both this view and its owner.
  PgnNodeData toPgnNodeData() => PgnNodeData(
    san: san,
    comments: comments == null ? null : List.of(comments!),
    startingComments: startingComments == null
        ? null
        : List.of(startingComments!),
    nags: nags == null ? null : List.of(nags!),
  );
}
