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

import 'package:flutter/foundation.dart';

import '../constants/engine_defaults.dart';
import '../models/opening_tree.dart';
import '../models/repertoire_line.dart';
import '../services/opening_tree_builder.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import '../services/repertoire_service.dart';
import '../services/storage/storage_factory.dart';
import 'repertoire_authoring.dart';

// ---------------------------------------------------------------------------
// Isolate-safe top-level helper for parsing repertoire lines (used by compute)
// ---------------------------------------------------------------------------

List<RepertoireLine> _parseRepertoireInIsolate(
  ({String pgn, String color}) args,
) {
  final service = RepertoireService();
  return service.parseRepertoirePgn(args.pgn, trainingColor: args.color);
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

/// Turns a repertoire PGN into a [LoadedRepertoire]. Stateless apart from its
/// [RepertoireAuthoring] collaborator, so one instance can serve overlapping
/// loads.
class RepertoireLoader {
  RepertoireLoader({RepertoireAuthoring? authoring})
    : _authoring = authoring ?? RepertoireAuthoring();

  final RepertoireAuthoring _authoring;

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
    final built = await _buildOpeningTree(pgnText);
    final lines = await _parseLines(
      pgnText,
      isWhite: built.headers?.isWhite ?? fallbackIsWhite,
    );
    return LoadedRepertoire(
      pgn: pgnText,
      openingTree: built.tree,
      lines: lines,
      headers: built.headers,
    );
  }

  /// Parses repertoire lines for the PGN browser.
  Future<List<RepertoireLine>> _parseLines(
    String? pgnText, {
    required bool isWhite,
  }) async {
    if (pgnText == null || pgnText.isEmpty) return const [];
    try {
      final lines = await compute(_parseRepertoireInIsolate, (
        pgn: pgnText,
        color: isWhite ? 'white' : 'black',
      ));
      debugPrint('Parsed ${lines.length} repertoire lines for PGN browser');
      return lines;
    } catch (e) {
      debugPrint('Failed to parse repertoire lines: $e');
      return const [];
    }
  }

  /// Builds an opening tree from [pgnText], alongside the headers read off it.
  Future<({OpeningTree tree, RepertoireHeaders? headers})> _buildOpeningTree(
    String? pgnText,
  ) async {
    if (pgnText == null || pgnText.isEmpty) {
      return (tree: OpeningTree(), headers: null);
    }

    try {
      final headers = parseRepertoireHeaders(pgnText);

      final processedGames = <String>[];
      for (final chunk in pgn.splitPgnIntoGames(pgnText)) {
        final tags = pgn.extractHeaders(chunk);
        final moveLines = <String>[];
        for (final line in chunk.split('\n')) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('[')) continue;
          moveLines.add(trimmed);
        }
        if (moveLines.isEmpty) continue;

        final game = _authoring.buildGame(
          event: tags['Event'],
          date: tags['Date'],
          white: tags['White'],
          black: tags['Black'],
          result: tags['Result'],
          moveLines: moveLines,
        );
        if (game != null) processedGames.add(game);
      }

      if (processedGames.isEmpty) {
        debugPrint('No games processed for tree building');
        return (tree: OpeningTree(), headers: headers);
      }

      final tree = await OpeningTreeBuilder.buildTree(
        pgnList: processedGames,
        username: '',
        userIsWhite: headers.isWhite,
        maxDepth: kOpeningTreeMaxDepth,
        strictPlayerMatching: false,
      );
      debugPrint('Built opening tree with ${tree.totalGames} total games');
      return (tree: tree, headers: headers);
    } catch (e) {
      debugPrint('Failed to build opening tree: $e');
      return (tree: OpeningTree(), headers: null);
    }
  }
}

/// Reads the `// Color:` / `// Root:` comment block off [pgnText].
@visibleForTesting
RepertoireHeaders parseRepertoireHeaders(String pgnText) {
  String? color;
  String? rootMoves;
  for (final line in pgnText.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('// Color:')) {
      color = trimmed.substring(9).trim();
    } else if (trimmed.startsWith('// Root:')) {
      rootMoves = trimmed.substring(8).trim();
    }
  }
  return RepertoireHeaders(
    rootMoves: rootMoves ?? '',
    isWhite: color != 'Black',
    needsColorSelection: color == null,
  );
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
