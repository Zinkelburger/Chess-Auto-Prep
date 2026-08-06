part of 'tactics_import_service.dart';

/// Whether the game's `Date`/`UTCDate` header is before [cutoff] (day
/// granularity). Games without a parseable date pass the filter — better
/// to analyze one game too many than silently drop it.
bool _isGameBefore(String gameText, DateTime cutoff) {
  final match = RegExp(
    r'\[(?:Date|UTCDate) "(\d{4})\.(\d{2})\.(\d{2})"\]',
  ).firstMatch(gameText);
  if (match == null) return false;
  final gameDate = DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
  return gameDate.isBefore(DateTime(cutoff.year, cutoff.month, cutoff.day));
}

/// Extract game ID from PGN headers.
///
/// Lichess provides the game URL in the [Site] header, Chess.com in [Link].
/// Both APIs always include one of these, so we only handle those two
/// sources (plus our own injected [GameId] header). Returns empty string
/// if no ID can be determined, which causes the game to be analyzed every
/// time (safe fallback).
///
/// Always returns a platform-prefixed ID (`lichess_` / `chesscom_`) —
/// [resumeStoredPgns] routes games to the right username by that prefix,
/// so an unprefixed ID would make a game unresumable.
String _extractGameId(String gameText) {
  // 1. A GameId header — ours from a previous import, or Lichess's own:
  //    their PGN exports natively carry the bare game ID in [GameId].
  //    Only trust it as-is when it already has a platform prefix.
  final rawHeaderId = RegExp(
    r'\[GameId "([^"]+)"\]',
  ).firstMatch(gameText)?.group(1);
  if (rawHeaderId != null &&
      (rawHeaderId.startsWith('lichess_') ||
          rawHeaderId.startsWith('chesscom_'))) {
    return rawHeaderId;
  }

  // 2. Chess.com: [Link "https://www.chess.com/game/live/123456789"]
  final linkMatch = RegExp(r'\[Link "([^"]+)"\]').firstMatch(gameText);
  if (linkMatch != null) {
    final link = linkMatch.group(1)!;
    final match = RegExp(r'/(\d+)(?:\?|$|#)').firstMatch(link);
    if (match != null) {
      return 'chesscom_${match.group(1)}';
    }
    // Fallback: last path segment
    final parts = link.split('/');
    final lastPart = parts.where((p) => p.isNotEmpty).lastOrNull;
    if (lastPart != null && lastPart.toLowerCase() != 'chess.com') {
      return 'chesscom_$lastPart';
    }
  }

  // 3. Lichess: [Site "https://lichess.org/AbCdEfGh"]
  final siteMatch = RegExp(r'\[Site "([^"]+)"\]').firstMatch(gameText);
  if (siteMatch != null) {
    final site = siteMatch.group(1)!;
    if (site.toLowerCase().contains('lichess.org/')) {
      final parts = site.split('/');
      final gameId = parts
          .where((p) => p.isNotEmpty && !p.contains('.'))
          .lastOrNull;
      if (gameId != null && gameId.length >= 6) {
        return 'lichess_$gameId';
      }
    }
  }

  // 4. A bare GameId header with no Site/Link to attribute it — only
  //    Lichess emits a native GameId header, so prefix accordingly.
  if (rawHeaderId != null && rawHeaderId.isNotEmpty) {
    return 'lichess_$rawHeaderId';
  }

  // No recognizable game ID found
  if (kDebugMode) {
    log.w('Warning: could not extract game ID from PGN headers');
  }
  return '';
}

/// Inject GameId header into PGN if not present
String _injectGameIdHeader(String gameText) {
  // Check if GameId already exists
  if (gameText.contains('[GameId ')) {
    return gameText;
  }

  final gameId = _extractGameId(gameText);

  // Find where to insert (after last header, before moves)
  final lines = gameText.split('\n');
  final result = <String>[];
  bool addedGameId = false;

  for (final line in lines) {
    result.add(line);
    final trimmed = line.trim();
    if (!addedGameId && trimmed.startsWith('[') && trimmed.endsWith(']')) {
      final nextIndex = lines.indexOf(line) + 1;
      if (nextIndex < lines.length) {
        final nextLine = lines[nextIndex].trim();
        if (!nextLine.startsWith('[') && nextLine.isNotEmpty) {
          result.add('[GameId "$gameId"]');
          addedGameId = true;
        }
      }
    }
  }

  // If we didn't add it yet (edge case), add before moves
  if (!addedGameId) {
    // Find first non-header line
    for (int i = 0; i < result.length; i++) {
      if (!result[i].trim().startsWith('[') && result[i].trim().isNotEmpty) {
        result.insert(i, '[GameId "$gameId"]');
        break;
      }
    }
  }

  return result.join('\n');
}

/// Extract the user's Elo from the first game in the batch.
///
/// Parses PGN headers to find `WhiteElo` / `BlackElo` for the side matching
/// [username]. Returns `null` if the header is missing or unparseable.
int? _extractUserElo(String gameText, String username) {
  final game = PgnGame.parsePgn(gameText);
  final white = (game.headers['White'] ?? '').toLowerCase();
  final black = (game.headers['Black'] ?? '').toLowerCase();
  final uLower = username.toLowerCase();

  String? eloHeader;
  if (white == uLower) {
    eloHeader = game.headers['WhiteElo'];
  } else if (black == uLower) {
    eloHeader = game.headers['BlackElo'];
  }
  if (eloHeader == null) return null;
  return int.tryParse(eloHeader.replaceAll('?', ''));
}
