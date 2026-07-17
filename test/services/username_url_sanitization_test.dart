import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/services/chess_api_urls.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart';

/// Username -> URL sanitization tests.
///
/// Every production site that turns a username into a Lichess/Chess.com request
/// URL now routes through the pure builders in `lib/services/chess_api_urls.dart`
/// ([lichessUserGamesUrl], [chesscomArchivesUrl]), so these tests exercise the
/// REAL code path (no mirroring). Call sites:
///   * lib/services/tactics_import_service.dart  (Lichess games, Chess.com archives)
///   * lib/services/analysis_games_service.dart  (Lichess games, Chess.com archives)
///   * lib/services/games_library/games_library_service.dart (Lichess games)
///
/// The security property under test: a username is encoded as a SINGLE path
/// segment, so a hostile value (`a/../../admin`, `victim?x=1`, `victim#f`) can
/// neither traverse to a different endpoint nor inject/erase query parameters,
/// and the host is never attacker-controllable.
void main() {
  group('lichessUserGamesUrl — normal usernames', () {
    test('plain alphanumeric builds expected host/path/query', () {
      final u = lichessUserGamesUrl('MagnusCarlsen', {'evals': 'false'});
      expect(u.scheme, 'https');
      expect(u.host, 'lichess.org');
      expect(u.path, '/api/games/user/MagnusCarlsen');
      expect(u.queryParameters['evals'], 'false');
    });

    test('hyphen/underscore/dot are preserved verbatim (no-op encoding)', () {
      final u = lichessUserGamesUrl('cool-user_42.x', const {});
      expect(u.path, '/api/games/user/cool-user_42.x');
      expect(u.pathSegments.last, 'cool-user_42.x');
    });

    test('digits-only username is fine', () {
      final u = lichessUserGamesUrl('12345', const {});
      expect(u.path, '/api/games/user/12345');
    });

    test('multiple query params are all preserved', () {
      final u = lichessUserGamesUrl('alice', const {
        'evals': 'false',
        'max': '20',
        'moves': 'true',
      });
      expect(u.queryParameters['evals'], 'false');
      expect(u.queryParameters['max'], '20');
      expect(u.queryParameters['moves'], 'true');
    });
  });

  group('lichessUserGamesUrl — adversarial usernames are neutralized', () {
    test('"../" segments CANNOT traverse to a different endpoint', () {
      final u = lichessUserGamesUrl('a/../../admin', {'evals': 'false'});
      // Whole hostile string stays one segment under /user/.
      expect(u.path.startsWith('/api/games/user/'), isTrue);
      expect(u.pathSegments.length, 4); // api, games, user, <encoded>
      expect(u.pathSegments.last, 'a/../../admin'); // decoded, single segment
      expect(u.host, 'lichess.org');
      // The app's own query survives intact.
      expect(u.queryParameters['evals'], 'false');
    });

    test('"?" in username CANNOT inject a query parameter', () {
      final u = lichessUserGamesUrl('victim?max=99999', {'max': '20'});
      expect(u.pathSegments.last, 'victim?max=99999');
      expect(u.queryParameters['max'], '20'); // app value, not injected 99999
      expect(u.queryParameters.length, 1);
    });

    test('"#" in username CANNOT truncate the query via a fragment', () {
      final u = lichessUserGamesUrl('victim#frag', {'evals': 'false'});
      expect(u.queryParameters['evals'], 'false');
      expect(u.fragment, isEmpty);
      expect(u.pathSegments.last, 'victim#frag');
    });

    test('leading "//" cannot hijack the host', () {
      final u = lichessUserGamesUrl('/evil.com/x', const {});
      expect(u.host, 'lichess.org');
      expect(u.pathSegments.last, '/evil.com/x');
    });

    test('a full URL as a username stays a single inert segment', () {
      final u = lichessUserGamesUrl('https://evil.com/steal', const {});
      expect(u.host, 'lichess.org');
      expect(u.path.startsWith('/api/games/user/'), isTrue);
      expect(u.pathSegments.last, 'https://evil.com/steal');
    });

    test('space and unicode are encoded, host unchanged', () {
      final u = lichessUserGamesUrl('twö words', const {});
      expect(u.host, 'lichess.org');
      expect(u.pathSegments.last, 'twö words');
      expect(u.toString(), contains('tw%C3%B6%20words'));
    });
  });

  group('chesscomArchivesUrl', () {
    test('normal username is lowercased into the expected path', () {
      final u = chesscomArchivesUrl('HikaruNakamura');
      expect(u.scheme, 'https');
      expect(u.host, 'api.chess.com');
      expect(u.path, '/pub/player/hikarunakamura/games/archives');
    });

    test('hyphen/underscore preserved', () {
      final u = chesscomArchivesUrl('foo-bar_1');
      expect(u.path, '/pub/player/foo-bar_1/games/archives');
    });

    test('"../" CANNOT traverse to a different player/endpoint', () {
      final u = chesscomArchivesUrl('a/../../admin');
      // /player/ and /games/archives stay put; the name is one middle segment.
      expect(u.pathSegments, [
        'pub',
        'player',
        'a/../../admin',
        'games',
        'archives',
      ]);
      expect(u.path.contains('/player/'), isTrue);
      expect(u.host, 'api.chess.com');
    });

    test('"?" CANNOT inject into the archives query', () {
      final u = chesscomArchivesUrl('victim?inject=1');
      expect(u.query, isEmpty);
      expect(u.pathSegments[2], 'victim?inject=1');
      expect(u.host, 'api.chess.com');
    });
  });

  group('empty / whitespace / very long usernames', () {
    test('empty username yields a bare user segment, no crash', () {
      final u = lichessUserGamesUrl('', const {});
      expect(u.host, 'lichess.org');
      expect(u.path, '/api/games/user/');
    });

    test('whitespace-only username is encoded, not split', () {
      final u = lichessUserGamesUrl('   ', const {});
      expect(u.host, 'lichess.org');
      expect(u.toString(), contains('%20'));
    });

    test('very long username (10k chars) is handled without throwing', () {
      final long = 'a' * 10000;
      final u = lichessUserGamesUrl(long, const {});
      expect(u.host, 'lichess.org');
      expect(u.pathSegments.last.length, 10000);
    });

    test('empty chess.com username yields an empty player segment', () {
      final u = chesscomArchivesUrl('');
      expect(u.host, 'api.chess.com');
      expect(u.path, '/pub/player//games/archives');
    });
  });

  // ── Returned-PGN parsing robustness (public seam) ─────────────────────────
  // The bodies these URLs fetch are parsed by these functions; assert they
  // stay graceful on malformed / missing / duplicated / injection-like input.

  group('extractHeaders robustness', () {
    test('empty string -> empty map, no throw', () {
      expect(extractHeaders(''), isEmpty);
    });

    test('no headers (move text only) -> empty map', () {
      expect(extractHeaders('1. e4 e5 2. Nf3 *'), isEmpty);
    });

    test('well-formed headers parsed into a map', () {
      final h = extractHeaders('[White "Alice"]\n[Black "Bob"]\n\n1. e4 *');
      expect(h['White'], 'Alice');
      expect(h['Black'], 'Bob');
    });

    test('duplicated header keys -> last value wins, no throw', () {
      final h = extractHeaders('[White "first"]\n[White "second"]');
      expect(h['White'], 'second');
    });

    test('unterminated tag (missing closing quote/bracket) is ignored', () {
      final h = extractHeaders('[White "unclosed\n[Black "Bob"]');
      expect(h.containsKey('White'), isFalse);
      expect(h['Black'], 'Bob');
    });

    test('injection-like header value is captured verbatim, no crash', () {
      final h = extractHeaders(
        '[Site "https://evil.com/x?a=b&c=d"]\n'
        '[White "]injection[ attempt"]',
      );
      expect(h['Site'], 'https://evil.com/x?a=b&c=d');
      expect(h.containsKey('White'), isTrue);
    });

    test('header value containing "]" does not break subsequent parsing', () {
      final h = extractHeaders('[Event "a]b]c"]\n[Round "1"]');
      expect(h['Event'], 'a]b]c');
      expect(h['Round'], '1');
    });

    test('huge header value does not throw', () {
      final big = 'x' * 50000;
      final h = extractHeaders('[Event "$big"]');
      expect(h['Event']!.length, 50000);
    });
  });

  group('splitPgnIntoGames / count robustness', () {
    test('empty content -> no games', () {
      expect(splitPgnIntoGames(''), isEmpty);
      expect(countPgnGames(''), 0);
    });

    test('whitespace-only content -> no games', () {
      expect(splitPgnIntoGames('   \n\n  \t'), isEmpty);
    });

    test('malformed / header-less move text is treated as a single game', () {
      final games = splitPgnIntoGames('1. e4 e5 2. Nf3 Nc6');
      expect(games, hasLength(1));
      expect(countPgnGames('1. e4 e5'), 1);
    });

    test('two [Event]-delimited games split into two', () {
      const pgn = '[Event "A"]\n\n1. e4 *\n\n[Event "B"]\n\n1. d4 *';
      expect(splitPgnIntoGames(pgn), hasLength(2));
      expect(countPgnGames(pgn), 2);
      expect(countPgnGamesFast(pgn), 2);
    });

    test('unterminated / junk header lines do not throw', () {
      const pgn = '[Event "A"\n[White "x]\n1. e4 *';
      final games = splitPgnIntoGames(pgn);
      expect(games, isNotEmpty);
    });

    test('stripBom removes a leading BOM and is a no-op otherwise', () {
      expect(stripBom('﻿[Event "A"]'), '[Event "A"]');
      expect(stripBom('[Event "A"]'), '[Event "A"]');
      expect(stripBom(''), '');
    });

    test('very large multi-game input counts without throwing', () {
      final buf = StringBuffer();
      for (var i = 0; i < 500; i++) {
        buf.write('[Event "G$i"]\n\n1. e4 e5 *\n\n');
      }
      final pgn = buf.toString();
      expect(countPgnGamesFast(pgn), 500);
      expect(splitPgnIntoGames(pgn), hasLength(500));
    });
  });
}
