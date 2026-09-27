import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'dart:isolate';

import 'package:dartchess/dartchess.dart';

import '../models/opening_tree.dart';
import '../utils/chess_utils.dart' show tryParseFen;
import '../utils/fen_utils.dart' show expandFen;
import '../utils/isolate_task.dart';
import '../utils/log.dart';
import 'pgn_tree_core.dart';

/// Builds an [OpeningTree] from a player's games or a course's chapters.
///
/// [buildTree] does the work in a background isolate; [addGames] and
/// [addGame] grow a tree the caller already holds, for callers that have
/// parsed their games once for other purposes.
class OpeningTreeBuilder {
  /// Games between progress reports from [buildTree].
  static const int _progressEvery = 25;

  /// Build a tree from [pgnList] in a background isolate.
  ///
  /// Each element of [pgnList] must contain exactly one game (headers +
  /// moves). Multi-game strings in a single element are **not** expanded —
  /// only the first game will be parsed. Callers should pre-split if needed.
  ///
  /// [onProgress] receives (processed, total) as the batch is folded.
  static Future<OpeningTree> buildTree({
    required List<String> pgnList,
    required String username,
    required bool? userIsWhite,
    int maxDepth = 30,
    bool strictPlayerMatching = true,
    bool? includeVariations,
    bool preserveSetupRoots = false,
    void Function(int processed, int total)? onProgress,
    IsolateTask? task,
  }) async {
    final args = (
      pgnList: pgnList,
      username: username,
      userIsWhite: userIsWhite,
      maxDepth: maxDepth,
      strictPlayerMatching: strictPlayerMatching,
      includeVariations: includeVariations,
      preserveSetupRoots: preserveSetupRoots,
      reportProgress: onProgress != null,
    );
    final transferJson = await (task ?? IsolateTask())
        .run<Map<String, dynamic>>(
          _bindEntry(_buildTreeEntry, args),
          onProgress: (message) {
            final progress = message as List;
            onProgress?.call(progress[0] as int, progress[1] as int);
          },
        );
    return OpeningTree.fromTransferJson(transferJson);
  }

  /// Isolate entry: builds the tree and streams `[processed, total]` back on
  /// [progress] when asked to.
  static Map<String, dynamic> _buildTreeEntry(
    _BuildArgs args,
    SendPort progress,
  ) {
    final tree = OpeningTree(preserveSetupRoots: args.preserveSetupRoots);
    final usernameLower = args.username.toLowerCase();
    final total = args.pgnList.length;
    var processed = 0;
    var skipped = 0;

    void report() {
      if (args.reportProgress) progress.send([processed, total]);
    }

    report();

    // Chapters go in after the games that reach their start position, so the
    // tree does not depend on the order the collection happens to be sorted
    // in; see [foldGamesIntoTree]. The start position is read from the raw
    // text, so a big collection is still parsed one game at a time.
    foldGamesIntoTree<String>(
      games: args.pgnList,
      startPositionOf: _startPositionOfText,
      isReached: (position) => treeReachesPosition(tree, position),
      fold: (pgnText) {
        final trimmed = pgnText.trim();
        if (trimmed.isNotEmpty) {
          try {
            addGame(
              tree,
              parsePgnGame(trimmed),
              usernameLower: usernameLower,
              userIsWhite: args.userIsWhite,
              maxDepth: args.maxDepth,
              strictPlayerMatching: args.strictPlayerMatching,
              includeVariations: args.includeVariations,
            );
          } catch (_) {
            // One malformed game must not sink the collection; counted and
            // logged below.
            skipped++;
          }
        }
        processed++;
        if (processed == total ||
            processed == 1 ||
            processed % _progressEvery == 0) {
          report();
        }
      },
    );

    if (skipped > 0) {
      log.w(
        '[OpeningTreeBuilder] Skipped $skipped malformed games out of $total',
      );
    }

    return tree.toTransferJson();
  }

  /// Fold a whole batch of parsed games into [tree], in an order that does
  /// not depend on the order they arrived in — see [foldGamesIntoTree].
  ///
  /// Prefer this to a loop over [addGame] whenever the caller has all its
  /// games in hand: folding a `[FEN]` chapter before the game that reaches
  /// its start position grafts it at the root instead of anchoring it, and
  /// the graft is never revisited.
  static void addGames(
    OpeningTree tree,
    Iterable<PgnGame<PgnNodeData>> games, {
    required String usernameLower,
    required bool? userIsWhite,
    required int maxDepth,
    required bool strictPlayerMatching,
    bool? includeVariations,
    void Function(PgnGame<PgnNodeData> game, Object error)? onError,
  }) {
    foldGamesIntoTree<PgnGame<PgnNodeData>>(
      games: games,
      startPositionOf: _startPositionOf,
      isReached: (position) => treeReachesPosition(tree, position),
      fold: (game) {
        try {
          addGame(
            tree,
            game,
            usernameLower: usernameLower,
            userIsWhite: userIsWhite,
            maxDepth: maxDepth,
            strictPlayerMatching: strictPlayerMatching,
            includeVariations: includeVariations,
          );
        } catch (e) {
          if (onError == null) rethrow;
          onError(game, e);
        }
      },
    );
  }

  /// Fold one parsed [game] into [tree] under the builder's attribution
  /// rules.  Public so a caller that has already parsed its games (the
  /// repertoire loader parses each game once for lines *and* tree) can grow
  /// a tree without re-serialising and re-parsing them.
  ///
  /// Folding a batch one call at a time re-introduces the ordering problem
  /// [addGames] exists to avoid; use [addGames] when the games are all in
  /// hand.
  static void addGame(
    OpeningTree tree,
    PgnGame<PgnNodeData> game, {
    required String usernameLower,
    required bool? userIsWhite,
    required int maxDepth,
    required bool strictPlayerMatching,
    bool? includeVariations,
  }) {
    final result = (game.headers['Result'] ?? '*').trim();

    // Games whose colour can't be determined are skipped.
    final isUserWhiteInGame = resolveUserColor(
      whiteHeader: game.headers['White'] ?? '',
      blackHeader: game.headers['Black'] ?? '',
      usernameLower: usernameLower,
      userIsWhiteFilter: userIsWhite,
      strictPlayerMatching: strictPlayerMatching,
      unattributablePolicy: UnattributableGamePolicy.skip,
    );
    if (isUserWhiteInGame == null) return;

    // Course / unfinished games (`*`) count toward frequency without a fake
    // 50% draw bar on the opening tree.
    final userResult = (result.isEmpty || result == '*')
        ? null
        : resultForUser(result, isUserWhiteInGame);

    // Course / repertoire lines (`*`) fold RAVs into the tree so the viewer
    // Tree tab shows every book continuation, not just each chapter's
    // mainline. Scored player games stay mainline-only — their variations
    // are analysis notes, not extra games.
    //
    // A `[FEN]` chapter starts its walk from that position: replaying its
    // first move from the standard start fails, and the whole chapter used
    // to vanish from the tree at ply 1.
    walkMainlineIntoTree(
      tree: tree,
      game: game,
      userResult: userResult,
      maxDepth: maxDepth,
      startPosition: _startPositionOf(game),
      includeVariations: includeVariations ?? userResult == null,
    );
  }

  /// The position a game starts from: its `[FEN]` header when it carries one
  /// (the same lenient rule the repertoire lines use — no `[SetUp]` needed),
  /// else the standard start.
  static Position? _startPositionOf(PgnGame<PgnNodeData> game) {
    final fen = game.headers['FEN']?.trim();
    if (fen == null || fen.isEmpty) return null;
    return tryParseFen(expandFen(fen));
  }

  /// [_startPositionOf] read straight off the PGN text, so a batch can be
  /// ordered without parsing every game up front (a big collection is parsed
  /// one game at a time, and holding every parse would cost far more than the
  /// text itself).
  ///
  /// A `[FEN "…"]` that turns out to be inside a comment only defers the game
  /// to the second pass, where its start position resolves to the root and it
  /// is folded straight away.
  static Position? _startPositionOfText(String pgnText) {
    const tag = '[FEN "';
    final start = pgnText.indexOf(tag);
    if (start < 0) return null;
    final end = pgnText.indexOf('"]', start + tag.length);
    if (end < 0) return null;
    final fen = pgnText.substring(start + tag.length, end).trim();
    if (fen.isEmpty) return null;
    return tryParseFen(expandFen(fen));
  }
}

typedef _BuildArgs = ({
  List<String> pgnList,
  String username,
  bool? userIsWhite,
  int maxDepth,
  bool strictPlayerMatching,
  bool? includeVariations,
  bool preserveSetupRoots,
  bool reportProgress,
});

/// Binds [args] to [entry] in a scope of its own, so the closure handed to
/// the isolate captures plain data and never the caller's progress callback.
R Function(SendPort) _bindEntry<R, A>(
  R Function(A args, SendPort progress) entry,
  A args,
) =>
    (port) => entry(args, port);
