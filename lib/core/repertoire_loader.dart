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

import '../constants/engine_defaults.dart';
import '../models/opening_tree.dart';
import '../models/repertoire_line.dart';
import '../services/opening_tree_builder.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import '../services/repertoire_service.dart';
import '../services/storage/storage_factory.dart';

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
  );

  final tree = OpeningTree();
  for (final game in parsed) {
    // A game with no moves is not a line and was never counted before.
    if (game.game.moves.children.isEmpty) continue;
    try {
      OpeningTreeBuilder.addGame(
        tree,
        game.game,
        usernameLower: '',
        userIsWhite: args.isWhite,
        maxDepth: args.maxDepth,
        strictPlayerMatching: false,
      );
    } catch (e) {
      debugPrint('Skipping game ${game.index} in the opening tree: $e');
    }
  }

  return (tree: tree.toTransferJson(), lines: lines);
}

/// The `// Color:` / `// Root:` block a repertoire file carries above its
/// first `[Event]` tag.
///
/// Only produced when the PGN actually parsed; a missing file, a read failure
/// or a tree-build error leaves it null, which tells the caller to keep the
/// headers it already had.
@immutable
class RepertoireHeaders {
  const RepertoireHeaders({
    required this.rootMoves,
    required this.isWhite,
    required this.needsColorSelection,
  });

  /// Movetext of the saved root position (`// Root:`), empty when unset.
  final String rootMoves;

  /// Whether this is a White repertoire. Anything but `// Color: Black`
  /// — including a missing header — reads as White.
  final bool isWhite;

  /// True when the file carried no `// Color:` header at all, so the user
  /// still has to pick a side.
  final bool needsColorSelection;
}

/// Everything one repertoire load produces, computed without touching
/// controller state so a superseded load can be discarded whole.
@immutable
class LoadedRepertoire {
  const LoadedRepertoire({
    required this.pgn,
    required this.openingTree,
    required this.lines,
    required this.headers,
  });

  /// The PGN text this result was derived from, or null when there was none.
  final String? pgn;

  /// Null only for [missing] — a file that does not exist. An unparsable or
  /// empty PGN still yields an empty [OpeningTree].
  final OpeningTree? openingTree;

  final List<RepertoireLine> lines;

  /// Null when the PGN could not be read far enough to determine them; the
  /// caller then keeps its current headers.
  final RepertoireHeaders? headers;

  /// The result for a repertoire with no readable file behind it.
  static const missing = LoadedRepertoire(
    pgn: null,
    openingTree: null,
    lines: <RepertoireLine>[],
    headers: null,
  );
}

/// Turns a repertoire PGN into a [LoadedRepertoire].  Stateless, so one
/// instance can serve overlapping loads.
class RepertoireLoader {
  RepertoireLoader();

  /// Reads [filePath]. `exists` distinguishes "no such file" (the caller
  /// clears its opening tree) from "read as empty" (an empty tree is built).
  Future<({bool exists, String? pgn})> read(String filePath) async {
    final storage = StorageFactory.instance;
    if (!await storage.fileExists(filePath)) {
      return (exists: false, pgn: null);
    }
    return (exists: true, pgn: await storage.readFile(filePath));
  }

  /// Derives the opening tree, headers and parsed lines for [pgnText].
  ///
  /// [fallbackIsWhite] is the colour to parse lines with when the PGN did not
  /// yield headers of its own — the caller's current side.
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

/// Reads the `// Color:` / `// Root:` comment block off [pgnText].
///
/// A file with no `// Color:` line is not automatically a question for the
/// user: a repertoire this app generated says whose it is in its own first
/// `[Event]` tag ("… : Repertoire for Black", written by
/// [CourseTitles.courseTitle]), and an imported course usually says the same
/// thing in the same words. Reading it there is strictly better than asking,
/// because the file is the authority and the user is guessing at what is in
/// it.
@visibleForTesting
RepertoireHeaders parseRepertoireHeaders(String pgnText) {
  String? color;
  String? rootMoves;
  bool? inferred;
  // The block lives above the first game — [upsertMetadataComment] puts it
  // there — so the scan stops at the first `[Event ` line instead of
  // splitting the whole file into lines to look at its top.
  var lineStart = 0;
  while (lineStart <= pgnText.length) {
    var lineEnd = pgnText.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = pgnText.length;
    final trimmed = pgnText.substring(lineStart, lineEnd).trim();
    lineStart = lineEnd + 1;
    if (trimmed.startsWith('// Color:')) {
      color = trimmed.substring(9).trim();
    } else if (trimmed.startsWith('// Root:')) {
      rootMoves = trimmed.substring(8).trim();
    } else if (trimmed.startsWith('[Event ')) {
      inferred = _colorFromEventTag(trimmed);
      break;
    }
  }
  return RepertoireHeaders(
    rootMoves: rootMoves ?? '',
    isWhite: color != null ? color != 'Black' : (inferred ?? true),
    // Only ask when neither the comment nor the file's own title says.
    needsColorSelection: color == null && inferred == null,
  );
}

/// Whose repertoire an `[Event ...]` tag says it is, or null when it does not
/// say. Matches the phrasing this app writes and the one Chessable-style
/// course exports use; anything else stays null rather than guessing from,
/// say, an opening name that merely sounds like a defence.
bool? _colorFromEventTag(String eventLine) {
  final lower = eventLine.toLowerCase();
  final white = lower.contains('for white');
  final black = lower.contains('for black');
  // Both, or neither, is not evidence.
  if (white == black) return null;
  return white;
}

/// Replaces the `$prefix ...` comment line in [content], or inserts one above
/// the first `[Event ]` tag (or at the very top when there is none).
///
/// Duplicates collapse: every later line with the same prefix is dropped.
String upsertMetadataComment(String content, String prefix, String value) {
  final lines = content.split('\n');
  final updated = <String>[];
  var inserted = false;

  for (final line in lines) {
    final trimmed = line.trim();

    if (trimmed.startsWith(prefix)) {
      if (!inserted) {
        updated.add('$prefix $value');
        inserted = true;
      }
      continue;
    }

    if (!inserted && trimmed.startsWith('[Event ')) {
      updated.add('$prefix $value');
      inserted = true;
    }

    updated.add(line);
  }

  if (!inserted) {
    updated.insert(0, '$prefix $value');
  }

  return updated.join('\n');
}
