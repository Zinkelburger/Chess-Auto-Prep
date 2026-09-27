/// Reads a repertoire PGN file and derives everything a controller swaps in.
///
/// Split out of `RepertoireController` so that a load produces a *value*
/// ([LoadedRepertoire]) instead of writing controller state as it goes. That
/// matters for correctness, not just tidiness: the derivation spans two
/// isolate hops (opening-tree build, line parse), and a repertoire switch
/// during either one used to let the losing load write its half of the result
/// anyway. With the whole result in hand the caller can check its epoch once
/// and then apply all of it or none of it.
library;

import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../constants/engine_defaults.dart';
import '../../models/opening_tree.dart';
import '../../models/repertoire_line.dart';
import '../../services/opening_tree_builder.dart';
import '../../chess_core/pgn/pgn_text.dart' as pgn;
import '../../services/repertoire_service.dart';
import '../../features/repertoires/repositories/repertoire_decoder.dart';
import '../../features/repertoires/models/loaded_repertoire.dart';
import '../../chess_core/pgn/repertoire_headers.dart';

// ---------------------------------------------------------------------------
// Isolate-safe top-level helper: one split, one parse per game, two products
// ---------------------------------------------------------------------------

/// Everything a chapter load derives from its games, computed in one pass.
///
/// A load used to run two isolates over the same text — one splitting and
/// parsing every game for the opening tree (after re-serialising each game
/// through `buildGame`), the other splitting and parsing every game again
/// for the lines.  Both products come from the same parse now.
typedef _LoadedGames = ({
  Map<String, dynamic> tree,
  List<RepertoireLine> lines,
});

_LoadedGames _loadGamesInIsolate(
  ({String pgn, bool isWhite, int maxDepth}) args,
) {
  final service = RepertoireService();
  final text = pgn.stripBom(args.pgn);
  final parsed = service.parseGames(pgn.splitPgnIntoGames(text));

  final lines = service.linesFromParsedGames(
    parsed,
    declaredColor: args.isWhite ? 'white' : 'black',
    courseChapter: pgn.extractCourseChapter(text),
  );

  final tree = OpeningTree();
  // A game with no moves is not a line and was never counted before.
  // `addGames`, not a loop over `addGame`: a chapter that starts from a
  // `[FEN]` header has to be folded after whatever reaches that position, or
  // it is grafted at the root and the file's chapter order decides the tree.
  OpeningTreeBuilder.addGames(
    tree,
    parsed
        .where((game) => game.game.moves.children.isNotEmpty)
        .map((game) => game.game),
    usernameLower: '',
    userIsWhite: args.isWhite,
    maxDepth: args.maxDepth,
    strictPlayerMatching: false,
    onError: (game, e) {
      final index = parsed.firstWhere((p) => identical(p.game, game)).index;
      debugPrint('Skipping game $index in the opening tree: $e');
    },
  );

  return (tree: tree.toTransferJson(), lines: lines);
}

/// Turns a repertoire PGN into a [LoadedRepertoire].  Stateless, so one
/// instance can serve overlapping loads.
class IsolateRepertoireDecoder implements RepertoireDecoder {
  const IsolateRepertoireDecoder();

  /// Derives the opening tree, headers and parsed lines for [pgnText].
  ///
  /// [fallbackIsWhite] is the colour to parse lines with when the PGN did not
  /// yield headers of its own — the caller's current side.
  @override
  Future<LoadedRepertoire> build(
    String? pgnText, {
    required bool fallbackIsWhite,
  }) async {
    if (pgnText == null || pgnText.isEmpty) {
      return LoadedRepertoire(
        pgn: pgnText,
        openingTree: OpeningTree(),
        lines: const [],
        headers: null,
      );
    }

    final RepertoireHeaders headers;
    try {
      headers = parseRepertoireHeaders(pgnText);
    } catch (e) {
      debugPrint('Failed to read repertoire headers: $e');
      return LoadedRepertoire(
        pgn: pgnText,
        openingTree: OpeningTree(),
        lines: const [],
        headers: null,
      );
    }

    final _LoadedGames loaded;
    try {
      loaded = await Isolate.run(
        () => _loadGamesInIsolate((
          pgn: pgnText,
          isWhite: headers.isWhite,
          maxDepth: kOpeningTreeMaxDepth,
        )),
      );
    } catch (e) {
      debugPrint('Failed to load repertoire games: $e');
      return LoadedRepertoire(
        pgn: pgnText,
        openingTree: OpeningTree(),
        lines: const [],
        headers: headers,
      );
    }

    final tree = OpeningTree.fromTransferJson(loaded.tree);
    debugPrint(
      'Built opening tree with ${tree.totalGames} total games; '
      'parsed ${loaded.lines.length} repertoire lines',
    );
    return LoadedRepertoire(
      pgn: pgnText,
      openingTree: tree,
      lines: loaded.lines,
      headers: headers,
    );
  }
}
