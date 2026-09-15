/// Downloads a player's games from Lichess and Chess.com for the tactics
/// import. Returns raw PGN; the import service owns storing and analyzing it.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../services/chess_api_urls.dart';
import '../../../services/lichess_api_client.dart';
import '../../../services/pgn_parsing_service.dart' show splitPgnIntoGames;
import '../../../utils/log.dart';
import 'tactics_import_pgn_helpers.dart' show isGameBefore;

/// Default game count for a "latest N games" Lichess import.
const int kDefaultLichessImportGames = 20;

/// Default game count for a "latest N games" Chess.com import.
const int kDefaultChesscomImportGames = 10;

class TacticsGameFetcher {
  const TacticsGameFetcher();

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
    final response = await LichessApiClient.instance.get(
      lichessUserGamesUrl(username, params),
      extraHeaders: {'Accept': 'application/x-chess-pgn'},
    );
    if (response == null) {
      throw Exception('Failed to fetch games from Lichess (request failed)');
    }
    if (response.statusCode != 200) {
      throw Exception(
        'Failed to fetch games from Lichess: ${response.statusCode}',
      );
    }
    return response.body;
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

    // Use the archives endpoint to discover which months actually have
    // games, rather than blindly checking the last N months (which fails
    // for inactive players).
    final archives = await _fetchArchives(username);
    if (archives.isEmpty) {
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
