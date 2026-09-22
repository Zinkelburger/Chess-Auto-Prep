import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../chess/explorer_answer.dart';
import '../chess/explorer_choice.dart';
import '../chess/fen.dart';
import '../diagnostics/log.dart';

/// The Lichess opening explorer: the masters database and the Lichess
/// players' database, one request per position, and the PGN of a game
/// either one names.
///
/// The old app's policy, kept: at least 100 ms between requests, a request
/// that dies on the way is tried three times, and a 429 shuts the door for
/// a minute, then two, then four, so the position after it is answered as
/// rate-limited at once rather than by another request Lichess would
/// refuse. The door opens again on the first answer that comes through.

/// What one position is asked about.
final class ExplorerQuery {
  const ExplorerQuery(this.fen, this.choice);

  final Fen fen;
  final ExplorerChoice choice;

  bool get masters => choice.source == ExplorerSource.masters;
}

sealed class ExplorerFetch {
  const ExplorerFetch();
}

final class ExplorerFetched extends ExplorerFetch {
  const ExplorerFetched(this.answer);

  final ExplorerAnswer answer;
}

/// Why the answer did not arrive. The sentence is what the tab shows.
enum ExplorerProblem {
  unreachable('Could not reach the Lichess database — it needs a connection.'),
  rateLimited('Lichess is rate-limiting requests.'),
  rejected(
    'Lichess turned the request away. Add your Lichess token in Settings '
    'and try again.',
  ),
  http('Lichess could not answer.');

  const ExplorerProblem(this.sentence);

  final String sentence;
}

final class ExplorerNotFetched extends ExplorerFetch {
  const ExplorerNotFetched(this.problem, {this.status});

  final ExplorerProblem problem;

  /// The HTTP status, when the problem was one.
  final int? status;

  String get sentence => status == null
      ? problem.sentence
      : '${problem.sentence} It answered HTTP $status.';
}

/// The network is a real boundary: [LichessExplorerApi] in the app, a
/// scripted one in tests, which never reach it.
abstract interface class LichessExplorer {
  Future<ExplorerFetch> fetch(ExplorerQuery query);

  /// The PGN of the game [id] names, or null when it cannot be fetched.
  Future<String?> gamePgn(String id, {required bool masters});
}

/// How long one request may take before it counts as not arriving.
const explorerTimeout = Duration(seconds: 15);

/// The least time between two requests to Lichess.
const explorerMinimumGap = Duration(milliseconds: 100);

/// How long the door stays shut after a 429: this, then double, then double
/// again, until an answer comes through.
const explorerBackoff = Duration(seconds: 60);
const explorerBackoffMost = Duration(seconds: 240);

/// How many times a request that throws is tried.
const explorerAttempts = 3;

const _explorerHost = 'explorer.lichess.ovh';
const _siteHost = 'lichess.org';

final class LichessExplorerApi implements LichessExplorer {
  LichessExplorerApi(
    this._client, {
    required Future<String?> Function() token,
    DateTime Function() now = DateTime.now,
    Future<void> Function(Duration) wait = _sleep,
  }) : _token = token,
       _now = now,
       _wait = wait;

  final http.Client _client;

  /// The user's Lichess token, read at the call and never logged.
  final Future<String?> Function() _token;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _wait;

  DateTime? _lastRequest;
  DateTime? _shutUntil;
  Duration _backoff = explorerBackoff;

  static Future<void> _sleep(Duration d) => Future<void>.delayed(d);

  @override
  Future<ExplorerFetch> fetch(ExplorerQuery query) async {
    if (_shut) return const ExplorerNotFetched(ExplorerProblem.rateLimited);
    final response = await _get(_url(query), 'ask the explorer');
    if (response == null) {
      return const ExplorerNotFetched(ExplorerProblem.unreachable);
    }
    if (response.statusCode == 429) {
      _shutTheDoor();
      return const ExplorerNotFetched(ExplorerProblem.rateLimited);
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      log.w('ask the explorer', 'HTTP ${response.statusCode}');
      return const ExplorerNotFetched(ExplorerProblem.rejected);
    }
    if (response.statusCode != 200) {
      log.w('ask the explorer', 'HTTP ${response.statusCode}');
      return ExplorerNotFetched(
        ExplorerProblem.http,
        status: response.statusCode,
      );
    }
    _backoff = explorerBackoff;
    try {
      return ExplorerFetched(parseExplorerAnswer(response.body));
    } on FormatException catch (error) {
      log.w('read the explorer answer', error);
      return const ExplorerNotFetched(ExplorerProblem.http);
    }
  }

  @override
  Future<String?> gamePgn(String id, {required bool masters}) async {
    if (_shut) return null;
    final safe = Uri.encodeComponent(id);
    final url = masters
        ? Uri.https(_explorerHost, '/masters/pgn/$safe')
        : Uri.https(_siteHost, '/game/export/$safe', {
            'evals': '0',
            'clocks': '0',
            'literate': '0',
          });
    final response = await _get(
      url,
      'fetch the game $id',
      accept: 'application/x-chess-pgn',
    );
    if (response == null) return null;
    if (response.statusCode == 429) _shutTheDoor();
    if (response.statusCode != 200) {
      log.w('fetch the game $id', 'HTTP ${response.statusCode}');
      return null;
    }
    final pgn = const Utf8Decoder(
      allowMalformed: true,
    ).convert(response.bodyBytes).trim();
    return pgn.isEmpty ? null : pgn;
  }

  bool get _shut {
    final until = _shutUntil;
    return until != null && _now().isBefore(until);
  }

  void _shutTheDoor() {
    log.w(
      'ask the explorer',
      'HTTP 429; not asking for ${_backoff.inSeconds} s',
    );
    _shutUntil = _now().add(_backoff);
    if (_backoff < explorerBackoffMost) _backoff *= 2;
  }

  /// One request, [explorerAttempts] times over when it throws, never
  /// sooner than [explorerMinimumGap] after the last. Null when every
  /// attempt threw.
  Future<http.Response?> _get(Uri url, String action, {String? accept}) async {
    final headers = await _headers(accept);
    for (var attempt = 1; attempt <= explorerAttempts; attempt++) {
      await _keepTheGap();
      try {
        return await _client
            .get(url, headers: headers)
            .timeout(explorerTimeout);
      } on Object catch (error) {
        log.w('$action (attempt $attempt)', error);
      }
    }
    return null;
  }

  Future<void> _keepTheGap() async {
    final last = _lastRequest;
    if (last != null) {
      final since = _now().difference(last);
      if (since < explorerMinimumGap) await _wait(explorerMinimumGap - since);
    }
    _lastRequest = _now();
  }

  Future<Map<String, String>> _headers(String? accept) async {
    final token = await _token();
    return {
      'Accept': ?accept,
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  /// Masters lists up to 15 games; the players' database lists four top
  /// and four recent, as lila does.
  static Uri _url(ExplorerQuery query) => query.masters
      ? Uri.https(_explorerHost, '/masters', {
          'fen': query.fen.value,
          'topGames': '15',
        })
      : Uri.https(_explorerHost, '/lichess', {
          'variant': 'standard',
          'speeds': query.choice.speedsInOrder.map((s) => s.name).join(','),
          'ratings': query.choice.ratingsInOrder.join(','),
          'topGames': '4',
          'recentGames': '4',
          'fen': query.fen.value,
        });
}

/// The explorer's JSON as an answer. Throws [FormatException] when the text
/// is not the shape the API sends.
ExplorerAnswer parseExplorerAnswer(String body) {
  final data = jsonDecode(body);
  if (data is! Map<String, Object?>) {
    throw const FormatException('the explorer answer is not an object');
  }
  int count(Map<String, Object?> map, String key) => switch (map[key]) {
    final int n => n,
    _ => 0,
  };
  final moves = [
    for (final move in _maps(data['moves']))
      ExplorerMove(
        uci: '${move['uci'] ?? ''}',
        san: '${move['san'] ?? ''}',
        white: count(move, 'white'),
        draws: count(move, 'draws'),
        black: count(move, 'black'),
      ),
  ]..sort((a, b) => b.games.compareTo(a.games));
  final seen = <String>{};
  final games = [
    for (final game in [
      ..._maps(data['topGames']),
      ..._maps(data['recentGames']),
    ])
      if (seen.add('${game['id']}')) _game(game),
  ];
  return ExplorerAnswer(
    moves: moves,
    games: games,
    white: data['white'] is int ? data['white'] as int : null,
    draws: data['draws'] is int ? data['draws'] as int : null,
    black: data['black'] is int ? data['black'] as int : null,
  );
}

List<Map<String, Object?>> _maps(Object? list) => [
  if (list is List)
    for (final item in list)
      if (item is Map<String, Object?>) item,
];

ExplorerGame _game(Map<String, Object?> game) {
  final white = game['white'];
  final black = game['black'];
  String name(Object? player) =>
      player is Map<String, Object?> ? '${player['name'] ?? '?'}' : '?';
  int? rating(Object? player) =>
      player is Map<String, Object?> && player['rating'] is int
      ? player['rating'] as int
      : null;
  return ExplorerGame(
    id: '${game['id'] ?? ''}',
    white: name(white),
    black: name(black),
    whiteElo: rating(white),
    blackElo: rating(black),
    result: switch (game['winner']) {
      'white' => '1-0',
      'black' => '0-1',
      null => game.containsKey('winner') ? '1/2-1/2' : '*',
      _ => '*',
    },
    year: game['year'] is int ? game['year'] as int : null,
  );
}
