import 'package:chess_auto_prep/services/study_import/chessgames_collection_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shaped like the real collection page: each game linked twice (thumbnail +
/// move list), plus unrelated links carrying their own numbers.
const _collectionHtml = '''
<html><head><title>Chess collection: Fischer's 60 Memorable Games</title></head>
<body>
  <a href="/perl/chessgame?gid=1008366">Fischer vs Sherwin</a>
  <a href="/perl/chessgame?gid=1008366&kpage=2">moves</a>
  <a href="/perl/chessgame?gid=1044366">Fischer vs Larsen</a>
  <a href="/perl/chessplayer?pid=19233">Bobby Fischer</a>
</body></html>
''';

void main() {
  group('extractCollectionGameIds', () {
    test('returns page order, de-duplicated', () {
      expect(extractCollectionGameIds(_collectionHtml), ['1008366', '1044366']);
    });

    test('a WAF challenge page yields nothing — the blocked signal', () {
      const challenge =
          '<html><head><title>Request unsuccessful.</title></head>'
          '<body>Incapsula/AWS WAF</body></html>';
      expect(extractCollectionGameIds(challenge), isEmpty);
    });
  });

  group('extractCollectionTitle', () {
    test('strips the "Chess collection:" boilerplate', () {
      expect(
        extractCollectionTitle(_collectionHtml),
        "Fischer's 60 Memorable Games",
      );
    });

    test('unescapes entities', () {
      expect(
        extractCollectionTitle(
          '<title>Chess collection: Tal &amp; Botvinnik</title>',
        ),
        'Tal & Botvinnik',
      );
    });

    test('returns null when the page has no title', () {
      expect(
        extractCollectionTitle('<html><body>blocked</body></html>'),
        isNull,
      );
    });
  });

  group('parsePastedGameIds', () {
    test('reads ids out of pasted page source', () {
      expect(parsePastedGameIds(_collectionHtml), ['1008366', '1044366']);
    });

    test('reads a bare list of ids', () {
      expect(parsePastedGameIds('1008366\n1044366\n1008367'), [
        '1008366',
        '1044366',
        '1008367',
      ]);
    });

    test('ignores bare numbers when the text has real gid links', () {
      // pid=19233 must not become a game id just because it is a number.
      expect(parsePastedGameIds(_collectionHtml), isNot(contains('19233')));
    });
  });

  group('classifyPgnResponse', () {
    test('200 with PGN is a hit', () {
      final result = classifyPgnResponse(
        200,
        '\n[Event "World Championship"]\n[Site "?"]\n\n1. e4 e5 *\n',
      );
      expect(result.status, ChessgamesFetchStatus.ok);
      expect(result.pgn, startsWith('[Event '));
    });

    test('429 and 403 are throttles', () {
      expect(
        classifyPgnResponse(429, '').status,
        ChessgamesFetchStatus.throttled,
      );
      expect(
        classifyPgnResponse(403, '').status,
        ChessgamesFetchStatus.throttled,
      );
    });

    test('a 200 soft-ban page is a throttle, not a hit', () {
      // The failure mode that matters: chessgames.com answers a rate limit
      // with a 200 and an HTML page as often as with a 429.
      expect(
        classifyPgnResponse(
          200,
          '<html><body>You have made too many requests.</body></html>',
        ).status,
        ChessgamesFetchStatus.throttled,
      );
      expect(
        classifyPgnResponse(
          200,
          '<html><body>The site is under maintenance</body></html>',
        ).status,
        ChessgamesFetchStatus.throttled,
      );
    });

    test('a 404 or junk body is a skip, not a throttle', () {
      expect(
        classifyPgnResponse(404, 'Not found').status,
        ChessgamesFetchStatus.failed,
      );
      expect(
        classifyPgnResponse(200, '<html>no such game</html>').status,
        ChessgamesFetchStatus.failed,
      );
    });
  });
}
