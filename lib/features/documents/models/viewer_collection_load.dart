import '../../../models/pgn_game_entry.dart';
import 'pgn_document.dart';

/// A decoder transfers these fresh game entries to the receiving document.
/// Collection membership is fixed; the document owns subsequent game edits.
class DecodedPgnCollection {
  DecodedPgnCollection(Iterable<PgnGameEntry> games, this.preamble)
    : games = List.unmodifiable(games);
  final List<PgnGameEntry> games;
  final String preamble;
}

sealed class ViewerCollectionLoadResult {
  const ViewerCollectionLoadResult();
}

final class ViewerCollectionLoaded extends ViewerCollectionLoadResult {
  const ViewerCollectionLoaded(this.document, {this.snapshot, this.modified});
  final DecodedPgnCollection document;
  final PgnSnapshot? snapshot;
  final DateTime? modified;
}

enum ViewerCollectionLoadFailure {
  missing,
  unreadable,
  empty,
  noGames,
  decoding,
}

final class ViewerCollectionLoadFailed extends ViewerCollectionLoadResult {
  const ViewerCollectionLoadFailed(this.failure, [this.cause]);
  final ViewerCollectionLoadFailure failure;
  final Object? cause;
}
