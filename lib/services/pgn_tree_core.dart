/// Shared PGN game-attribution and tree-building core.
///
/// [OpeningTreeBuilder] and [UnifiedAnalysisBuilder] both parse PGN games,
/// decide which colour the user played, score the game from the user's
/// perspective, and walk moves into an [OpeningTree]. That logic lives
/// here so the two builders cannot drift apart.
///
/// Intentional per-builder differences are parameterized rather than
/// duplicated:
/// - what to do with a game whose user-colour cannot be determined
///   ([UnattributableGamePolicy]);
/// - the start position of the walk
///   ([walkMainlineIntoTree]'s `startPosition`);
/// - whether RAVs are folded in ([walkMainlineIntoTree]'s
///   `includeVariations` — true for course/repertoire `*` games).
library;

import 'package:dartchess/dartchess.dart';

import '../models/opening_tree.dart';
import '../models/pgn_filter_models.dart' show splitPlayerNames;
import '../core/pgn/pgn_dummy_mainline.dart';
import '../utils/chess_utils.dart' show isNullMoveSan, playSanOrNullMove;
import '../utils/fen_utils.dart' show normalizeFen;

/// Common player name patterns used in repertoire files.
const List<String> repertoirePlayerPatterns = [
  'repertoire',
  'training',
  'me',
  'player',
  'study',
];

/// Whether [playerName] matches any known repertoire player pattern.
///
/// Matches whole words, not substrings: a substring test would classify real
/// opponents like "Ga**me**r123" or "Ja**me**s" as repertoire placeholders,
/// making their games count for both colours with an inverted score on the
/// wrong-colour tree. App-generated placeholders ("Me", "Training",
/// "My Repertoire", …) are all whole words.
bool isRepertoirePlayer(String playerName) {
  final words = playerName.toLowerCase().split(_nonLetters);
  return words.any(repertoirePlayerPatterns.contains);
}

/// Hoisted: this runs twice per game while a tree is being built.
final RegExp _nonLetters = RegExp(r'[^a-z]+');

/// Whether [headerLower] names the user.
///
/// [usernameLower] may hold several `;`-separated names/abbreviations (see
/// [splitPlayerNames]); each is tried as a case-insensitive substring, so
/// "carlsen; drnykterstein" matches both "Carlsen, Magnus" and
/// "DrNykterstein". Both arguments must already be lower-cased. An empty or
/// all-separator [usernameLower] matches nothing.
bool userNameMatchesHeader(String headerLower, String usernameLower) =>
    splitPlayerNames(usernameLower).any(headerLower.contains);

/// How a player-name input matched a game collection's White/Black headers.
///
/// Built by [summarizePlayerNameMatches] so the UI can show *which* header
/// spellings a name search is currently hitting ("Carlsen, Magnus ×54,
/// Carlsen,M ×33") instead of asking the user to trust substring matching.
class PlayerNameMatchSummary {
  /// Games where at least one side matched.
  final int matchedGames;
  final int totalGames;

  /// Distinct header values that matched (original casing) → number of games
  /// they matched in, ordered by count descending.
  final Map<String, int> variantCounts;

  const PlayerNameMatchSummary({
    required this.matchedGames,
    required this.totalGames,
    required this.variantCounts,
  });

  int get unmatchedGames => totalGames - matchedGames;
}

/// Match [namesInput] (see [splitPlayerNames]) against every game's
/// White/Black headers, the same way game attribution does.
///
/// [includeRepertoirePlaceholders] additionally counts placeholder names
/// ("Me", "Training", …) as matches — pass true when previewing analysis
/// attribution (which treats them as the user), false for a pure name search.
PlayerNameMatchSummary summarizePlayerNameMatches({
  required Iterable<({String white, String black})> headerPairs,
  required String namesInput,
  bool includeRepertoirePlaceholders = false,
}) {
  final namesLower = namesInput.toLowerCase();
  final counts = <String, int>{};
  var matched = 0;
  var total = 0;

  bool sideMatches(String header) =>
      userNameMatchesHeader(header.toLowerCase(), namesLower) ||
      (includeRepertoirePlaceholders && isRepertoirePlayer(header));

  for (final pair in headerPairs) {
    total++;
    final whiteHit = pair.white.isNotEmpty && sideMatches(pair.white);
    final blackHit = pair.black.isNotEmpty && sideMatches(pair.black);
    if (whiteHit) counts[pair.white] = (counts[pair.white] ?? 0) + 1;
    if (blackHit) counts[pair.black] = (counts[pair.black] ?? 0) + 1;
    if (whiteHit || blackHit) matched++;
  }

  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return PlayerNameMatchSummary(
    matchedGames: matched,
    totalGames: total,
    variantCounts: {for (final e in sorted) e.key: e.value},
  );
}

/// What to do when the user's colour in a game cannot be determined from the
/// White/Black headers and no colour filter was supplied.
enum UnattributableGamePolicy {
  /// Skip the game entirely ([resolveUserColor] returns null).
  skip,

  /// Assume the user played White (arbitrary but consistent).
  assumeWhite,
}

/// Determine which colour the user played in a game.
///
/// Returns `true` if the user played White, `false` if Black, or `null` when
/// the game should be skipped.
///
/// [whiteHeader] and [blackHeader] are the raw `White`/`Black` PGN header
/// values (any case). [usernameLower] must already be lower-cased.
///
/// When [strictPlayerMatching] is false the headers are ignored entirely and
/// [userIsWhiteFilter] dictates the perspective (defaulting to White when the
/// filter is null).
///
/// When strict, a player header matches the user if it contains any of the
/// `;`-separated names in [usernameLower] (see [userNameMatchesHeader]) or
/// any of the [repertoirePlayerPatterns]. If exactly one
/// side matches, that side is the user. Ambiguous games (both or neither
/// side matches) fall back to [userIsWhiteFilter] when it is non-null;
/// otherwise [unattributablePolicy] decides between skipping the game and
/// assuming White. Finally, a non-null [userIsWhiteFilter] also acts as a
/// colour filter: games where the user played the other colour return null.
bool? resolveUserColor({
  required String whiteHeader,
  required String blackHeader,
  required String usernameLower,
  required bool? userIsWhiteFilter,
  required bool strictPlayerMatching,
  required UnattributableGamePolicy unattributablePolicy,
}) {
  if (!strictPlayerMatching) {
    // In repertoire mode we don't filter by name; the filter dictates the
    // perspective. With no filter, assume White (arbitrary but consistent).
    return userIsWhiteFilter ?? true;
  }

  final white = whiteHeader.toLowerCase();
  final black = blackHeader.toLowerCase();

  // Match by username OR any repertoire player pattern.
  final whiteIsUser =
      userNameMatchesHeader(white, usernameLower) || isRepertoirePlayer(white);
  final blackIsUser =
      userNameMatchesHeader(black, usernameLower) || isRepertoirePlayer(black);

  bool isUserWhiteInGame;
  if (whiteIsUser && !blackIsUser) {
    isUserWhiteInGame = true;
  } else if (blackIsUser && !whiteIsUser) {
    isUserWhiteInGame = false;
  } else if (userIsWhiteFilter != null) {
    // Both or neither match - use the filter to decide.
    isUserWhiteInGame = userIsWhiteFilter;
  } else if (unattributablePolicy == UnattributableGamePolicy.skip) {
    return null;
  } else {
    isUserWhiteInGame = true;
  }

  // Apply colour filter if specified.
  if (userIsWhiteFilter != null && userIsWhiteFilter != isUserWhiteInGame) {
    return null;
  }

  return isUserWhiteInGame;
}

/// Score a PGN `Result` header from the user's perspective:
/// 1.0 = user won, 0.0 = user lost, 0.5 = draw or unfinished (`*`).
double resultForUser(String result, bool userIsWhite) {
  final normalizedResult = result.trim();
  if (normalizedResult == '1-0') return userIsWhite ? 1.0 : 0.0;
  if (normalizedResult == '0-1') return userIsWhite ? 0.0 : 1.0;
  return 0.5; // Draws or '*'
}

/// Walk [game] into [tree], updating node stats with [userResult].
///
/// Starts from [startPosition] (defaults to the standard initial position)
/// but always grows the tree from `tree.root`. The walk stops at [maxDepth]
/// plies, on the first unparseable/illegal move, or at the end of the line.
///
/// When [includeVariations] is false (the default), only the mainline is
/// walked — right for scored player games, whose RAVs are analysis notes.
/// When true, every RAV is a separate line: ancestor frequency is incremented
/// once per path so sibling percentages still sum to 100%. Use that for
/// course / repertoire PGNs (`Result *`), where the variations *are* the
/// book. Chessable intro dummies (`1. Z0 (1. d4 …)`) are promoted to the
/// mainline first.
///
/// [onPositionBeforeMove] / [onWalkComplete] fire only on the mainline walk.
void walkMainlineIntoTree({
  required OpeningTree tree,
  required PgnGame<PgnNodeData> game,
  double? userResult,
  required int maxDepth,
  Position? startPosition,
  bool includeVariations = false,
  void Function(Position positionBeforeMove)? onPositionBeforeMove,
  void Function(Position finalPosition)? onWalkComplete,
}) {
  promoteNullMoveDummyMainline(game.moves);

  final position = startPosition ?? Chess.initial;

  // Where this game's first move hangs.  A `[FEN]` chapter starts mid-game, so
  // it belongs under the node that *is* its start position; only a game
  // starting where the tree does belongs at the root.
  final placed = _anchorNode(tree, position);

  // No node stands at that position, so the chapter is grafted at the root to
  // keep it visible — but [OpeningTree.advance] matches children by SAN
  // alone, and a graft is by definition not a real continuation of the root.
  // Reusing a root child that merely shares the SAN would fold the whole
  // chapter, stats included, into an unrelated line; [_graftStrict] refuses
  // that and only creates a node of its own.
  final anchor = placed ?? tree.root;
  final strictFirstPly = placed == null;

  tree.root.updateStats(userResult);
  if (!identical(anchor, tree.root)) anchor.updateStats(userResult);

  if (includeVariations) {
    _walkVariationsIntoTree(
      tree: tree,
      pgnNode: game.moves,
      pos: position,
      treeNode: anchor,
      depth: 0,
      maxDepth: maxDepth,
      userResult: userResult,
      strictFirstPly: strictFirstPly,
    );
    return;
  }

  var currentNode = anchor;
  var currentPos = position;
  var depth = 0;
  for (final nodeData in game.moves.mainline()) {
    if (depth >= maxDepth) break;

    onPositionBeforeMove?.call(currentPos);

    try {
      final moveSan = nodeData.san;
      if (isNullMoveSan(moveSan)) {
        // Pass the turn without a tree node so later same-side moves stay
        // legal and `--` does not pollute opening stats.
        final next = playSanOrNullMove(currentPos, moveSan);
        if (next == null) break;
        currentPos = next;
        continue;
      }

      final move = currentPos.parseSan(moveSan);
      if (move == null) break;

      currentPos = currentPos.play(move);

      final childNode = (strictFirstPly && depth == 0)
          ? _graftStrict(tree, currentNode, moveSan, currentPos)
          : tree.advance(currentNode, moveSan, currentPos);
      if (childNode == null) break; // would have merged into another line
      childNode.updateStats(userResult);

      currentNode = childNode;
      depth++;
    } catch (_) {
      break; // Stop if an illegal move is encountered.
    }
  }

  onWalkComplete?.call(currentPos);
}

/// [OpeningTree.advance] that refuses to reuse a child which merely shares
/// the SAN: null when one exists at a different position.
///
/// Only a graft needs this.  Down a real walk a SAN can only ever lead to one
/// position, so the check never fires; a grafted chapter's first move has no
/// such guarantee, and reuse there silently merges two unrelated lines.
OpeningTreeNode? _graftStrict(
  OpeningTree tree,
  OpeningTreeNode node,
  String san,
  Position positionAfter,
) {
  final existing = node.children[san];
  if (existing != null) {
    return normalizeFen(existing.fen) == normalizeFen(positionAfter.fen)
        ? existing
        : null;
  }
  return tree.advance(node, san, positionAfter);
}

/// The tree node a walk from [position] must start at: the root for a game
/// that starts where the tree does, otherwise the node already standing at
/// that position.  Null when the tree has never reached it.
///
/// Any of several transposing nodes is a legitimate home; the first indexed
/// one keeps the choice deterministic.
OpeningTreeNode? _anchorNode(OpeningTree tree, Position position) {
  final key = normalizeFen(position.fen);
  if (key == normalizeFen(tree.root.fen)) return tree.root;
  final nodes = tree.fenToNodes[key];
  return (nodes == null || nodes.isEmpty) ? null : nodes.first;
}

void _walkVariationsIntoTree({
  required OpeningTree tree,
  required PgnNode<PgnNodeData> pgnNode,
  required Position pos,
  required OpeningTreeNode treeNode,
  required int depth,
  required int maxDepth,
  required double? userResult,
  bool strictFirstPly = false,
}) {
  if (pgnNode.children.isEmpty || depth >= maxDepth) return;

  for (var i = 0; i < pgnNode.children.length; i++) {
    final child = pgnNode.children[i];
    try {
      final san = child.data.san;
      if (isNullMoveSan(san)) {
        final next = playSanOrNullMove(pos, san);
        if (next == null) continue;
        if (i > 0) _incrementPathStats(treeNode, userResult);
        _walkVariationsIntoTree(
          tree: tree,
          pgnNode: child,
          pos: next,
          treeNode: treeNode,
          depth: depth,
          maxDepth: maxDepth,
          userResult: userResult,
          strictFirstPly: strictFirstPly,
        );
        continue;
      }

      final move = pos.parseSan(san);
      if (move == null) continue;
      final next = pos.play(move);
      if (i > 0) _incrementPathStats(treeNode, userResult);
      final childNode = strictFirstPly
          ? _graftStrict(tree, treeNode, san, next)
          : tree.advance(treeNode, san, next);
      if (childNode == null) continue; // would have merged into another line
      childNode.updateStats(userResult);
      _walkVariationsIntoTree(
        tree: tree,
        pgnNode: child,
        pos: next,
        treeNode: childNode,
        depth: depth + 1,
        maxDepth: maxDepth,
        userResult: userResult,
      );
    } catch (_) {
      continue;
    }
  }
}

/// Add one more line through [node] and every ancestor, so a sideline's
/// frequency is counted on the shared prefix as well as on the branch.
void _incrementPathStats(OpeningTreeNode node, double? userResult) {
  OpeningTreeNode? n = node;
  while (n != null) {
    n.updateStats(userResult);
    n = n.parent;
  }
}
