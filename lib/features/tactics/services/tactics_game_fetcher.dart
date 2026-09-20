/// Downloads a player's games from Lichess and Chess.com for the tactics
/// import. Returns raw PGN; the import service owns storing and analyzing it.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../services/chess_api_urls.dart';
import '../../../services/games_library/games_library_service.dart';
import '../../../services/lichess_api_client.dart';
import '../../../chess_core/pgn/pgn_text.dart' show splitPgnIntoGames;
import '../../../utils/log.dart';
import 'tactics_import_pgn_helpers.dart' show isGameBefore;

/// Default game count for a "latest N games" Lichess import.
const int kDefaultLichessImportGames = 20;

/// Default game count for a "latest N games" Chess.com import.
const int kDefaultChesscomImportGames = 10;

class TacticsGameFetcher {
  const TacticsGameFetcher({GamesLibraryService? library}) : _library = library;

  /// Where the games already downloaded on this computer live. Consulted
  /// only when a download fails: reviewing the games you have beats telling
  /// someone with no connection that they have no games.
  final GamesLibraryService? _library;

  /// The saved games for this player, sliced the way the download would have
  /// been, or null when there are none.
  Future<List<String>?> _savedGames(
    GamesPlatform platform,
    String username, {
    int? maxGames,
    DateTime? since,
  }) async {
    final pgn = await (_library ?? GamesLibraryService()).cachedPgn(
      platform,
      username,
    );
    if (pgn == null) return null;
    var games = splitPgnIntoGames(pgn);
    if (since != null) {
      games = games.where((g) => !isGameBefore(g, since)).toList();
    }
    if (maxGames != null && games.length > maxGames) {
      games = games.take(maxGames).toList();
    }
    return games.isEmpty ? null : games;
  }

  static String _savedGamesMessage(String site, int count) =>
      'Could not reach $site — reviewing the $count game'
      '${count == 1 ? '' : 's'} saved on this computer.';

  /// The user's recent Lichess games as one PGN export, with clocks (they
  /// feed the tempo flaw tags). With [since], the window is the limit and
  /// [maxGames] only caps it when given; without, the latest [maxGames]
  /// (default [kDefaultLichessImportGames]).
  Future<String> fetchLichessPgn(
    String username, {
    int? maxGames,
    DateTime? since,
    void Function(String message)? progress,
  }) async {
    final params = <String, String>{
      'evals': 'false',
      'clocks': 'true',
      'opening': 'false',
      'moves': 'true',
    };
    if (since != null) {
      params['since'] = '${since.millisecondsSinceEpoch}';
      // No 'max' when the caller gave none: the since window is the limit,
      // and capping it would silently drop games the user asked for.
      if (maxGames != null) params['max'] = '$maxGames';
    } else {
      params['max'] = '${maxGames ?? kDefaultLichessImportGames}';
    }

    progress?.call('Downloading games from Lichess...');
    http.Response? response;
    Object? failure;
    try {
      response = await LichessApiClient.instance.get(
        lichessUserGamesUrl(username, params),
        extraHeaders: {'Accept': 'application/x-chess-pgn'},
      );
    } catch (e) {
      failure = e;
    }
    if (response != null && response.statusCode == 200) return response.body;

    // The download did not happen. Before failing the run, look at what this
    // computer already holds: offline, the saved games are the whole answer.
    final saved = await _savedGames(
      GamesPlatform.lichess,
      username,
      maxGames: since == null
          ? (maxGames ?? kDefaultLichessImportGames)
          : maxGames,
      since: since,
    );
    if (saved != null) {
      progress?.call(_savedGamesMessage('Lichess', saved.length));
      return saved.join('\n\n');
    }
    if (failure != null) {
      throw Exception('Failed to fetch games from Lichess: $failure');
    }
    if (response == null) {
      throw Exception('Failed to fetch games from Lichess (request failed)');
    }
    throw Exception(
      'Failed to fetch games from Lichess: ${response.statusCode}',
    );
  }

  /// The user's Chess.com games, newest archive month first, as separate
  /// PGN texts. [maxGames] null means no count limit (the [since] window is
  /// the only limit); without [since] the default is
  /// [kDefaultChesscomImportGames].
  ///
  /// Throws when the player has no archives or no games; returns an empty
  /// list when [isCancelled] turned true before any game arrived.
  Future<List<String>> fetchChesscomGames(
    String username, {
    int? maxGames,
    DateTime? since,
    void Function(String message)? progress,
    required bool Function() isCancelled,
  }) async {
    // null = no game-count limit: the since window is the only limit. Only
    // the countless "latest N games" mode falls back to a default.
    final int? targetGames =
        maxGames ?? (since != null ? null : kDefaultChesscomImportGames);

    progress?.call('Fetching Chess.com game archives for $username…');

    // What this computer already holds, for the paths below where nothing
    // was downloaded. Offline, these games are the whole answer.
    Future<List<String>?> savedGames() async {
      final saved = await _savedGames(
        GamesPlatform.chesscom,
        username,
        maxGames: targetGames,
        since: since,
      );
      if (saved != null) {
        progress?.call(_savedGamesMessage('Chess.com', saved.length));
      }
      return saved;
    }

    // Use the archives endpoint to discover which months actually have
    // games, rather than blindly checking the last N months (which fails
    // for inactive players).
    var archives = const <String>[];
    try {
      archives = await _fetchArchives(username);
    } catch (e) {
      if (kDebugMode) log.e('Error fetching Chess.com archives: $e');
    }
    if (archives.isEmpty) {
      if (await savedGames() case final saved?) return saved;
      throw Exception('No game archives found for $username on Chess.com');
    }
    final startArchiveIndex = since == null
        ? 0
        : firstArchiveIndexSince(archives, since);

    // Walk backwards from the most recent archive.
    var games = <String>[];
    for (
      var i = archives.length - 1;
      i >= startArchiveIndex &&
          (targetGames == null || games.length < targetGames) &&
          !isCancelled();
      i--
    ) {
      progress?.call(
        targetGames == null
            ? 'Downloading Chess.com games (${games.length})…'
            : 'Downloading Chess.com games (${games.length}/$targetGames)…',
      );
      try {
        final response = await http.get(Uri.parse('${archives[i]}/pgn'));
        if (response.statusCode == 200 && response.body.isNotEmpty) {
          games.addAll(splitPgnIntoGames(response.body));
        }
      } catch (e) {
        if (kDebugMode) log.e('Error fetching Chess.com games: $e');
      }
    }

    if (games.isEmpty) {
      if (isCancelled()) return const [];
      // Every archive request failed (they are caught one by one above), so
      // this is the same offline case as an unreachable archives endpoint.
      if (await savedGames() case final saved?) return saved;
      throw Exception('No games found for $username on Chess.com');
    }

    // Archive months are coarser than the window: drop the older games of
    // the first month by their Date header.
    if (since != null) {
      games = games.where((g) => !isGameBefore(g, since)).toList();
    }
    return targetGames == null ? games : games.take(targetGames).toList();
  }

  /// The player's monthly archive URLs in chronological order (oldest
  /// first), or an empty list if the player has no archives.
  Future<List<String>> _fetchArchives(String username) async {
    final response = await http.get(chesscomArchivesUrl(username));
    if (response.statusCode != 200) return [];
    final data = json.decode(response.body) as Map<String, dynamic>;
    return List<String>.from(data['archives'] as List);
  }

  /// Index of the first monthly archive (URLs like
  /// `https://api.chess.com/pub/player/<user>/games/2024/06`, oldest first)
  /// that can contain games played on or after [since]; 0 when none of the
  /// URLs carries a parseable year/month.
  @visibleForTesting
  static int firstArchiveIndexSince(List<String> archives, DateTime since) {
    for (var i = 0; i < archives.length; i++) {
      final parts = archives[i].split('/');
      if (parts.length < 2) continue;
      final year = int.tryParse(parts[parts.length - 2]);
      final month = int.tryParse(parts[parts.length - 1]);
      if (year == null || month == null) continue;
      if (year > since.year || (year == since.year && month >= since.month)) {
        return i;
      }
    }
    return 0;
  }
}
