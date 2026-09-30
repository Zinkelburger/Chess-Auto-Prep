import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../chess/pgn/game_text.dart';
import '../chess/players/download_range.dart';
import '../chess/tactics/game_ids.dart';
import '../diagnostics/log.dart';
import 'lichess_http.dart';

/// The user's own recent games, from Lichess or Chess.com, as PGN texts,
/// newest first. No login: a Lichess token, when the user has connected
/// one, only rides along as a bearer header and is left off when Lichess
/// refuses it.

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

/// Optional richer export used by player preparation; ordinary recent-game
/// callers retain their existing defaults and contract.
abstract interface class RangedGames implements RecentGames {
  Future<GamesFetch> range(
    String username,
    PlayerDownloadRange range, {
    required bool Function() cancelled,
    required void Function(String) progress,
  });
}

bool _neverCancel() => false;
void _noProgress(String _) {}

/// How long one request may take before it counts as not arriving. For the
/// Lichess export, which streams, it is how long the answer may take to start.
const gamesTimeout = Duration(seconds: 60);

/// How long the Lichess export may go quiet before it counts as stalled.
/// There is no limit on the whole export: Lichess sends a few dozen games a
/// second, so thousands of games take minutes.
const exportStallTimeout = Duration(seconds: 45);

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
final class LichessGamesApi implements RangedGames {
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
  Future<GamesFetch> recent(String username, {required int max}) =>
      _fetch(username, max: max);

  @override
  Future<GamesFetch> range(
    String username,
    PlayerDownloadRange range, {
    required bool Function() cancelled,
    required void Function(String) progress,
  }) => _fetch(
    username,
    max: range.months == null ? range.max : null,
    since: range.since(DateTime.now()),
    speeds: range.speeds,
    cancelled: cancelled,
    progress: progress,
  );

  Future<GamesFetch> _fetch(
    String username, {
    int? max,
    DateTime? since,
    Set<String>? speeds,
    bool Function() cancelled = _neverCancel,
    void Function(String) progress = _noProgress,
  }) async {
    final url = Uri.https(
      'lichess.org',
      '/api/games/user/${Uri.encodeComponent(username.trim())}',
      {
        if (max != null) 'max': '$max',
        if (since != null) 'since': '${since.millisecondsSinceEpoch}',
        'moves': 'true',
        'clocks': 'false',
        'evals': 'false',
        'opening': 'false',
        'perfType':
            speeds?.join(',') ??
            'ultraBullet,bullet,blitz,rapid,classical,correspondence',
      },
    );
    var headers = lichessHeaders(
      token: await _token(),
      accept: 'application/x-chess-pgn',
    );
    for (var attempt = 0; ; attempt++) {
      if (cancelled()) return const GamesFetched([]);
      var answer = await _stream(url, headers, cancelled, progress);
      // Lichess refuses a stale or revoked token instead of answering as
      // if there were none, but the export needs none: ask once without.
      if (answer?.statusCode == 401 &&
          headers.containsKey('Authorization') &&
          !cancelled()) {
        log.w('download Lichess games', 'token refused; retrying without it');
        headers = lichessHeaders(accept: 'application/x-chess-pgn');
        answer = await _stream(url, headers, cancelled, progress);
      }
      if (cancelled()) return const GamesFetched([]);
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
          progress(
            'Lichess download limit reached. Retrying in ${wait.inSeconds} seconds…',
          );
          await _pause(wait, cancelled);
        case _:
          return _games(answer, 'download Lichess games');
      }
    }
  }

  /// One export, read as it streams, with the games counted as they come.
  /// A request that does not finish — no start, a stall, a cancel, an
  /// error — is aborted before this returns, so a retry never runs beside
  /// it: Lichess allows one request at a time. Anything but a 200 comes
  /// back with an empty body.
  Future<http.Response?> _stream(
    Uri url,
    Map<String, String> headers,
    bool Function() cancelled,
    void Function(String) progress,
  ) async {
    final abort = Completer<void>();
    // A cancel aborts within a second, also while the answer has not
    // started or the export is quiet.
    final watch = Timer.periodic(const Duration(seconds: 1), (_) {
      if (cancelled() && !abort.isCompleted) abort.complete();
    });
    try {
      final response = await _client
          .send(
            http.AbortableRequest('GET', url, abortTrigger: abort.future)
              ..headers.addAll(headers),
          )
          .timeout(gamesTimeout);
      if (response.statusCode != 200) {
        unawaited(response.stream.listen(null).cancel());
        return http.Response.bytes(const [], response.statusCode);
      }
      final body = BytesBuilder(copy: false);
      var games = 0, tail = '';
      await for (final chunk in response.stream.timeout(exportStallTimeout)) {
        if (cancelled()) return null;
        body.add(chunk);
        final text = tail + latin1.decode(chunk);
        final found = '[Event '.allMatches(text).length;
        tail = text.substring(text.length < 6 ? 0 : text.length - 6);
        if (found > 0) {
          games += found;
          progress('$games games downloaded');
        }
      }
      return http.Response.bytes(body.takeBytes(), 200);
    } on Object catch (error) {
      if (!cancelled()) log.w('download ${url.host}', error.runtimeType);
      return null;
    } finally {
      watch.cancel();
      // After a finished read the abort has nothing left to close.
      if (!abort.isCompleted) abort.complete();
    }
  }

  /// [_wait] for [d], cut short within a second of [cancelled].
  Future<void> _pause(Duration d, bool Function() cancelled) async {
    final stop = Completer<void>();
    final poll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (cancelled() && !stop.isCompleted) stop.complete();
    });
    try {
      await Future.any([_wait(d), stop.future]);
    } finally {
      poll.cancel();
    }
  }
}

/// Chess.com's monthly archives: the list of months, then each month's PGN
/// from the newest, until there are enough games.
final class ChesscomGamesApi implements RangedGames {
  ChesscomGamesApi(this._client, {Wait wait = _sleep}) : _wait = wait;

  final http.Client _client;
  final Wait _wait;

  static const _headers = {'User-Agent': appUserAgent};

  @override
  GameSite get site => GameSite.chesscom;

  @override
  Future<GamesFetch> recent(String username, {required int max}) =>
      _fetch(username, max: max);

  @override
  Future<GamesFetch> range(
    String username,
    PlayerDownloadRange range, {
    required bool Function() cancelled,
    required void Function(String) progress,
  }) => _fetch(
    username,
    max: range.months == null ? range.max : null,
    range: range,
    cancelled: cancelled,
    progress: progress,
  );

  Future<GamesFetch> _fetch(
    String username, {
    int? max,
    PlayerDownloadRange? range,
    bool Function() cancelled = _neverCancel,
    void Function(String) progress = _noProgress,
  }) async {
    final name = Uri.encodeComponent(username.trim().toLowerCase());
    final listed = await _get(
      Uri.parse('https://api.chess.com/pub/player/$name/games/archives'),
    );
    final List<String> months;
    switch (listed) {
      case GamesNotFetched():
        return listed;
      case GamesFetched(:final games):
        final read = archivesNewestFirst(games.single);
        if (read == null) {
          log.w('download Chess.com games', 'archive list unreadable');
          return const GamesNotFetched(GamesProblem.http, status: 200);
        }
        months = read;
    }
    final found = <String>[];
    for (final month in months) {
      if (cancelled()) return const GamesFetched([]);
      if (max != null && found.length >= max) break;
      final cutoff = range?.since(DateTime.now());
      final date = _archiveDate(month);
      if (cutoff != null && date != null && date.isBefore(cutoff)) break;
      progress(
        '${found.length} games downloaded · ${date == null ? 'reading archive' : '${date.year}-${date.month}'}',
      );
      switch (await _get(Uri.parse('$month/pgn'))) {
        case final GamesNotFetched failed:
          return failed;
        case GamesFetched(:final games):
          found.addAll(
            splitGames(
              games.single,
            ).reversed.where((g) => range?.keeps(g, DateTime.now()) ?? true),
          );
      }
    }
    return GamesFetched(max == null ? found : found.take(max).toList());
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
/// nothing: a body that is not the list — a block or maintenance page, an
/// error object — is null, never an empty list of months.
List<String>? archivesNewestFirst(String body) {
  try {
    final data = jsonDecode(body);
    if (data is! Map || data['archives'] is! List) return null;
    return [
      for (final month in (data['archives'] as List).reversed)
        if (month is String) month,
    ];
  } on FormatException {
    return null;
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
    log.w('download ${url.host}', error.runtimeType);
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

DateTime? _archiveDate(String url) {
  final parts = Uri.tryParse(url)?.pathSegments ?? const <String>[];
  if (parts.length < 2) return null;
  final year = int.tryParse(parts[parts.length - 2]),
      month = int.tryParse(parts.last);
  return year == null || month == null ? null : DateTime(year, month);
}
