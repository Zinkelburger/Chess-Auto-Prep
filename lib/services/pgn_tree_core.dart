/// Shared PGN game-attribution and tree-building core.
///
/// [OpeningTreeBuilder] and [UnifiedAnalysisBuilder] both parse PGN games,
/// decide which colour the user played, score the game from the user's
/// perspective, and walk the mainline into an [OpeningTree]. That logic lives
/// here so the two builders cannot drift apart.
///
/// Intentional per-builder differences are parameterized rather than
/// duplicated:
/// - what to do with a game whose user-colour cannot be determined
///   ([UnattributableGamePolicy]);
/// - the start position of the mainline walk
///   ([walkMainlineIntoTree]'s `startPosition`).
library;

import 'package:dartchess/dartchess.dart';

import '../models/opening_tree.dart';
import '../models/pgn_filter_models.dart' show splitPlayerNames;

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
  final words = playerName.toLowerCase().split(RegExp(r'[^a-z]+'));
  return words.any(repertoirePlayerPatterns.contains);
}

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

/// Walk [game]'s mainline into [tree], updating node stats with [userResult].
///
/// Starts from [startPosition] (defaults to the standard initial position)
/// but always grows the tree from `tree.root`. The walk stops at [maxDepth]
/// plies, on the first unparseable/illegal move, or at the end of the
/// mainline.
///
/// [onPositionBeforeMove] is invoked with the position *before* each mainline
/// move is applied (only for plies actually visited, i.e. within [maxDepth]).
/// [onWalkComplete] is invoked once with the final position reached, whatever
/// caused the walk to stop.
void walkMainlineIntoTree({
  required OpeningTree tree,
  required PgnGame<PgnNodeData> game,
  required double userResult,
  required int maxDepth,
  Position? startPosition,
  void Function(Position positionBeforeMove)? onPositionBeforeMove,
  void Function(Position finalPosition)? onWalkComplete,
}) {
  Position position = startPosition ?? Chess.initial;
  var currentNode = tree.root;

  // Update root stats.
  currentNode.updateStats(userResult);

  int depth = 0;
  for (final nodeData in game.moves.mainline()) {
    if (depth >= maxDepth) break;

    onPositionBeforeMove?.call(position);

    try {
      final moveSan = nodeData.san;

      // Parse SAN into a Move object for the engine.
      final move = position.parseSan(moveSan);
      if (move == null) break;

      // Apply move.
      position = position.play(move);

      // Tree building.
      final childNode = currentNode.getOrCreateChild(moveSan, position.fen);
      childNode.updateStats(userResult);
      tree.indexNode(childNode);

      // Advance.
      currentNode = childNode;
      depth++;
    } catch (_) {
      break; // Stop if an illegal move is encountered.
    }
  }

  onWalkComplete?.call(position);
}
