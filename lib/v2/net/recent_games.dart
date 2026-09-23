import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../chess/pgn/game_text.dart';
import '../chess/tactics/game_ids.dart';
import '../diagnostics/log.dart';
import 'lichess_http.dart';

/// The user's own recent games, from Lichess or Chess.com, as PGN texts,
/// newest first. No login: a Lichess token, when the user has connected
/// one, only rides along as a bearer header.

sealed class GamesFetch {
  const GamesFetch();
}

final class GamesFetched extends GamesFetch {
  const GamesFetched(this.games);

  /// One PGN text per game, newest first.
  final List<String> games;
}

/// Why the games did not come down.
enum GamesProblem { unreachable, rateLimited, noSuchPlayer, http }

final class GamesNotFetched extends GamesFetch {
  const GamesNotFetched(this.problem, {this.status});

  final GamesProblem problem;

  /// The HTTP status, when the problem was one.
  final int? status;
}

/// One site's games. The network is a real boundary: these clients in the
/// app, a scripted one in tests.
abstract interface class RecentGames {
  GameSite get site;

  /// The newest [max] games [username] played.
  Future<GamesFetch> recent(String username, {required int max});
}

/// How long one request may take before it counts as not arriving.
const gamesTimeout = Duration(seconds: 60);

/// After a 429 Lichess is asked again after a minute, then two, then four;
/// a fourth 429 gives up. A request that dies on the way is tried again
/// after two seconds, up to the same number of times.
const lichessBackoff = Duration(seconds: 60);
const lichessRetries = 3;
const transportRetryDelay = Duration(seconds: 2);

typedef Wait = Future<void> Function(Duration);

Future<void> _sleep(Duration d) => Future<void>.delayed(d);

/// Lichess's game export: one request, the newest games first, standard
/// chess only (the variants are left out by speed).
final class LichessGamesApi implements RecentGames {
  LichessGamesApi(
    this._client, {
    required Future<String?> Function() token,
    Wait wait = _sleep,
  }) : _token = token,
       _wait = wait;

  final http.Client _client;
  final Future<String?> Function() _token;
  final Wait _wait;

  @override
  GameSite get site => GameSite.lichess;

  @override
  Future<GamesFetch> recent(String username, {required int max}) async {
    final url = Uri.https(
      'lichess.org',
      '/api/games/user/${Uri.encodeComponent(username.trim())}',
      {
        'max': '$max',
        'moves': 'true',
        'clocks': 'false',
        'evals': 'false',
        'opening': 'false',
        'perfType': 'ultraBullet,bullet,blitz,rapid,classical,correspondence',
      },
    );
    final headers = lichessHeaders(
      token: await _token(),
      accept: 'application/x-chess-pgn',
    );
    for (var attempt = 0; ; attempt++) {
      final answer = await _once(_client, url, headers);
      final last = attempt >= lichessRetries;
      switch (answer) {
        case null when !last:
          await _wait(transportRetryDelay);
        case http.Response(statusCode: 429) when !last:
          final wait = lichessBackoff * (1 << attempt);
          log.w(
            'download Lichess games',
            'HTTP 429; waiting ${wait.inSeconds} s',
          );
          await _wait(wait);
        case _:
          return _games(answer, 'download Lichess games');
      }
    }
  }
}

/// Chess.com's monthly archives: the list of months, then each month's PGN
/// from the newest, until there are enough games.
final class ChesscomGamesApi implements RecentGames {
  ChesscomGamesApi(this._client, {Wait wait = _sleep}) : _wait = wait;

  final http.Client _client;
  final Wait _wait;

  static const _headers = {'User-Agent': appUserAgent};

  @override
  GameSite get site => GameSite.chesscom;

  @override
  Future<GamesFetch> recent(String username, {required int max}) async {
    final name = Uri.encodeComponent(username.trim().toLowerCase());
    final listed = await _get(
      Uri.parse('https://api.chess.com/pub/player/$name/games/archives'),
    );
    final List<String> months;
    switch (listed) {
      case GamesNotFetched():
        return listed;
      case GamesFetched(:final games):
        months = archivesNewestFirst(games.single);
    }
    final found = <String>[];
    for (final month in months) {
      if (found.length >= max) break;
      switch (await _get(Uri.parse('$month/pgn'))) {
        case final GamesNotFetched failed:
          return failed;
        case GamesFetched(:final games):
          found.addAll(splitGames(games.single).reversed);
      }
    }
    return GamesFetched(found.take(max).toList());
  }

  /// One request, tried once more when it dies on the way; the body comes
  /// back as the only "game".
  Future<GamesFetch> _get(Uri url) async {
    var answer = await _once(_client, url, _headers);
    if (answer == null) {
      await _wait(transportRetryDelay);
      answer = await _once(_client, url, _headers);
    }
    return switch (_problem(answer, 'download Chess.com games')) {
      final GamesNotFetched failed => failed,
      null => GamesFetched([
        utf8.decode(answer!.bodyBytes, allowMalformed: true),
      ]),
    };
  }
}

/// The archive addresses of Chess.com's list, newest month first. Throws
/// nothing: a body that is not the list reads as no months.
List<String> archivesNewestFirst(String body) {
  try {
    final data = jsonDecode(body);
    if (data is! Map || data['archives'] is! List) return const [];
    return [
      for (final month in (data['archives'] as List).reversed)
        if (month is String) month,
    ];
  } on FormatException {
    return const [];
  }
}

/// The games of a multi-game PGN, each as its own text.
List<String> splitGames(String pgn) => [
  for (final game in splitChapterText(pgn).games) game.text,
];

Future<http.Response?> _once(
  http.Client client,
  Uri url,
  Map<String, String> headers,
) async {
  try {
    return await client.get(url, headers: headers).timeout(gamesTimeout);
  } on Object catch (error) {
    log.w('download ${url.host}', error);
    return null;
  }
}

GamesFetch _games(http.Response? answer, String action) =>
    switch (_problem(answer, action)) {
      final GamesNotFetched failed => failed,
      null => GamesFetched(
        splitGames(utf8.decode(answer!.bodyBytes, allowMalformed: true)),
      ),
    };

GamesNotFetched? _problem(http.Response? answer, String action) {
  if (answer == null) return const GamesNotFetched(GamesProblem.unreachable);
  final status = answer.statusCode;
  if (status == 200) return null;
  log.w(action, 'HTTP $status');
  return switch (status) {
    429 => const GamesNotFetched(GamesProblem.rateLimited, status: 429),
    404 => const GamesNotFetched(GamesProblem.noSuchPlayer, status: 404),
    _ => GamesNotFetched(GamesProblem.http, status: status),
  };
}
