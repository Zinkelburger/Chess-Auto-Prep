import 'package:chess_auto_prep/services/eval/lichess_eval_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Trimmed from database.lichess.org — the evals panel plus a neighbour, so
/// the "last updated" match cannot come from the wrong section.
const _page = '''
<section id="puzzles" class="panel">
  <p><strong>5,000,000</strong> puzzles.</p>
  <p>This file was last updated on 2025-01-01.</p>
</section>
<section id="evals" class="panel">
  <p>
    <strong>394,669,566</strong> chess positions evaluated with Stockfish.
    <br>
  <p>
    <a class="primary" href="lichess_db_eval.jsonl.zst">Download</a>
  </p>
  <p>
    This file was last updated on 2026-08-02.
  </p>
</section>
''';

void main() {
  group('parseLichessPositionCount', () {
    test('reads the advertised count', () {
      expect(parseLichessPositionCount(_page), 394669566);
    });

    test('null when the page changes shape', () {
      expect(parseLichessPositionCount('<p>no numbers here</p>'), isNull);
      expect(parseLichessPositionCount(''), isNull);
    });
  });

  group('parseLichessUpdatedOn', () {
    test('reads the date from the evals section, not an earlier one', () {
      expect(parseLichessUpdatedOn(_page), DateTime(2026, 8, 2));
    });

    test('falls back to the first date when there is no evals anchor', () {
      expect(
        parseLichessUpdatedOn('This file was last updated on 2024-03-04.'),
        DateTime(2024, 3, 4),
      );
    });

    test('null when no date is stated', () {
      expect(parseLichessUpdatedOn('<p>nothing</p>'), isNull);
    });
  });

  group('LichessEvalSourceInfo', () {
    test('the store size follows from the position count', () {
      const info = LichessEvalSourceInfo(
        bytes: 21681515630,
        lastModified: 'Sun, 02 Aug 2026 21:49:50 GMT',
        positions: 394669566,
        updatedOn: null,
      );
      // 15 bytes a position plus the header — about 5.9 GB.
      expect(info.storeBytes, 394669566 * 15 + 32);
      expect(info.storeBytes, lessThan(6000000000));
    });
  });

  group('probe', () {
    test('combines the HEAD and the page', () async {
      final source = LichessEvalSource(
        client: MockClient((request) async {
          if (request.method == 'HEAD') {
            return http.Response(
              '',
              200,
              headers: {
                'content-length': '21681515630',
                'last-modified': 'Sun, 02 Aug 2026 21:49:50 GMT',
              },
            );
          }
          return http.Response(_page, 200);
        }),
      );

      final info = await source.probe();
      expect(info.probed, isTrue);
      expect(info.bytes, 21681515630);
      expect(info.lastModified, 'Sun, 02 Aug 2026 21:49:50 GMT');
      expect(info.positions, 394669566);
      expect(info.updatedOn, DateTime(2026, 8, 2));
    });

    test('an unreachable site yields the built-in figures, flagged', () async {
      final source = LichessEvalSource(
        client: MockClient((_) async => throw const _Offline()),
      );
      final info = await source.probe();
      expect(info.probed, isFalse);
      expect(info.bytes, kLichessEvalFallbackBytes);
      expect(info.positions, kLichessEvalFallbackPositions);
    });

    test(
      'a reachable HEAD with an unreadable page still gives a size',
      () async {
        final source = LichessEvalSource(
          client: MockClient((request) async {
            if (request.method == 'HEAD') {
              return http.Response('', 200, headers: {'content-length': '123'});
            }
            return http.Response('gone', 404);
          }),
        );
        final info = await source.probe();
        expect(info.probed, isTrue);
        expect(info.bytes, 123);
        expect(info.positions, kLichessEvalFallbackPositions);
      },
    );
  });
}

class _Offline implements Exception {
  const _Offline();
}
