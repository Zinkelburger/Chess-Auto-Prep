/// Legacy collection merge helper. Production saves use the injected document
/// store and revision-aware collection editor.
library;

import '../../chess_core/pgn/pgn_collection.dart';
import '../../services/games_library/game_filter.dart' show dedupKeyForHeaders;
import '../../chess_core/pgn/pgn_text.dart' as pgn;

/// The file as it now stands on disk, with only the games *we* changed
/// substituted into it — the write to use when the file moved under us.
///
/// A viewer save rewrites the whole file from the collection in memory, which
/// is correct only while that memory is the newest copy. It is not, whenever
/// something else has written to the file since it was loaded: the app's own
/// review runner patches the games cache in place ([GamesLibraryService
/// .patchGameMovetexts]), and a reader can have the file open in an editor.
/// Rewriting from memory then silently reverts everything that arrived in
/// between — a star discarding an hour of engine review.
///
/// [gameTexts] is every game as we hold it, in collection order; [edited]
/// names the ones this session actually changed. Everything else comes from
/// [diskContent] verbatim, including its banner, its game order, and any game
/// we have never seen.
///
/// The merge only ever *substitutes*: nothing on disk is dropped, reordered,
/// or appended to. A game we cannot place unambiguously keeps the disk copy
/// and is named in [unplaced] — losing a star beats corrupting a file whose
/// shape we no longer recognise. Returns null when [diskContent] holds no
/// games at all, which is not a file this merge understands.
String? mergeEditedGamesIntoDiskCopy({
  required String diskContent,
  required List<String> gameTexts,
  required Set<int> edited,
  List<int>? unplaced,
}) {
  final chunks = pgn.splitPgnIntoGames(diskContent);
  if (chunks.isEmpty) return null;

  String keyOf(String gameText) =>
      dedupKeyForHeaders(pgn.extractHeaders(gameText));

  final diskKeys = [for (final c in chunks) keyOf(c)];

  // Same number of games, and the game at each edited index is still the game
  // we edited: the shape did not change, only the text inside it. This is the
  // case the review runner produces, and it needs no identity lookup at all.
  final sameShape = chunks.length == gameTexts.length;

  for (final index in edited) {
    if (index < 0 || index >= gameTexts.length) continue;
    final ours = gameTexts[index];
    final key = keyOf(ours);

    if (sameShape && (key.isEmpty || diskKeys[index] == key)) {
      chunks[index] = ours;
      continue;
    }

    // The shape moved. Place the game only where its identity is unambiguous
    // on both sides — one game on disk with that key, and one of ours.
    final matches = [
      for (var i = 0; i < diskKeys.length; i++)
        if (diskKeys[i] == key) i,
    ];
    final ourMatches = [
      for (var i = 0; i < gameTexts.length; i++)
        if (keyOf(gameTexts[i]) == key) i,
    ];
    if (key.isEmpty || matches.length != 1 || ourMatches.length != 1) {
      unplaced?.add(index);
      continue;
    }
    chunks[matches.single] = ours;
  }

  final preamble = pgnCollectionPreamble(diskContent);
  final body = [for (final c in chunks) c.trim()].join('\n\n');
  return preamble.isEmpty ? '$body\n' : '$preamble\n\n$body\n';
}
