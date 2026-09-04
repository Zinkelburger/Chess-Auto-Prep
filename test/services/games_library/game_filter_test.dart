import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';

String game({
  required String white,
  required String black,
  required String date,
  String? time,
  String? tc,
  String? link,
  String moves = '1. e4 e5 2. Nf3 *',
}) {
  final b = StringBuffer()
    ..writeln('[Event "Rated game"]')
    ..writeln('[White "$white"]')
    ..writeln('[Black "$black"]')
    ..writeln('[UTCDate "$date"]');
  if (time != null) b.writeln('[UTCTime "$time"]');
  if (tc != null) b.writeln('[TimeControl "$tc"]');
  if (link != null) b.writeln('[Link "$link"]');
  b
    ..writeln()
    ..writeln(moves);
  return b.toString();
}

void main() {
  group('classifySpeed', () {
    test('buckets by estimated duration', () {
      expect(classifySpeed('60'), GameSpeed.bullet);
      expect(classifySpeed('180'), GameSpeed.blitz);
      expect(classifySpeed('300'), GameSpeed.blitz);
      expect(classifySpeed('300+5'), GameSpeed.rapid); // 300+200=500
      expect(classifySpeed('600'), GameSpeed.rapid);
      expect(classifySpeed('1800'), GameSpeed.classical);
      expect(classifySpeed('15'), GameSpeed.ultraBullet);
      expect(classifySpeed('-'), GameSpeed.correspondence);
      expect(classifySpeed('1/259200'), GameSpeed.correspondence);
      expect(classifySpeed(null), GameSpeed.unknown);
    });

    test('ultraBullet stops at half a minute', () {
      expect(classifySpeed('29'), GameSpeed.ultraBullet);
      expect(classifySpeed('30'), GameSpeed.bullet);
    });

    test('an increment is worth 40 moves of thinking time', () {
      // 139 + 40 = 179s, one second short of blitz; one more second of base
      // lands exactly on it.
      expect(classifySpeed('139+1'), GameSpeed.bullet);
      expect(classifySpeed('140+1'), GameSpeed.blitz);
      // The multiplier, not the base, is what carries a short game over a
      // bucket line: 20+3 is a bullet game, not an ultraBullet one.
      expect(classifySpeed('20+3'), GameSpeed.bullet);
    });
  });

  group('GameRecord.date', () {
    GameRecord recordFor({required String date, String? time}) =>
        parseGameRecords(
          game(white: 'me', black: 'a', date: date, time: time, tc: '300'),
        ).single;

    test('reads the clock time off the UTCTime header', () {
      expect(
        recordFor(date: '2026.06.01', time: '13:45:07').date,
        DateTime.utc(2026, 6, 1, 13, 45, 7),
      );
    });

    test('a game with no time is placed at midnight, not later in the day', () {
      final timeless = recordFor(date: '2026.06.01');
      expect(timeless.date, DateTime.utc(2026, 6, 1));

      // Which is what a `since` on that midnight has to include, and a
      // `since` one second later has to exclude.
      final records = [timeless];
      expect(
        applySelection(records, GameSelection(since: DateTime.utc(2026, 6, 1))),
        hasLength(1),
      );
      expect(
        applySelection(
          records,
          GameSelection(since: DateTime.utc(2026, 6, 1, 0, 0, 1)),
        ),
        isEmpty,
      );
    });
  });

  group('mergeGamePgns', () {
    test('an empty cache takes the fresh games with nothing prepended', () {
      final fresh = [
        game(white: 'me', black: 'a', date: '2026.06.01', tc: '300'),
        game(white: 'me', black: 'b', date: '2026.06.02', tc: '300'),
      ].join('\n\n');

      final merged = mergeGamePgns(existing: '', fresh: fresh);

      expect(merged, startsWith('[Event '));
      expect(parseGameRecords(merged), hasLength(2));
    });
  });

  group('applySelection', () {
    test('keeps only allowed speeds', () {
      final pgn = [
        game(white: 'me', black: 'a', date: '2026.06.01', tc: '60'), // bullet
        game(white: 'me', black: 'b', date: '2026.06.02', tc: '300'), // blitz
      ].join('\n\n');

      final kept = applySelection(
        parseGameRecords(pgn),
        const GameSelection(speeds: {GameSpeed.blitz}),
      );
      expect(kept.length, 1);
      expect(kept.single.black, 'b');
    });

    test('caps to maxGames, newest first', () {
      final pgn = [
        game(white: 'me', black: 'old', date: '2026.01.01', tc: '300'),
        game(white: 'me', black: 'mid', date: '2026.03.01', tc: '300'),
        game(white: 'me', black: 'new', date: '2026.06.01', tc: '300'),
      ].join('\n\n');

      final kept = applySelection(
        parseGameRecords(pgn),
        const GameSelection(maxGames: 2),
      );
      expect(kept.map((r) => r.black), ['new', 'mid']);
    });

    test('filters by since date', () {
      final pgn = [
        game(white: 'me', black: 'old', date: '2026.01.01', tc: '300'),
        game(white: 'me', black: 'new', date: '2026.06.01', tc: '300'),
      ].join('\n\n');

      final kept = applySelection(
        parseGameRecords(pgn),
        GameSelection(since: DateTime.utc(2026, 5, 1)),
      );
      expect(kept.map((r) => r.black), ['new']);
    });

    test('de-duplicates by link', () {
      final pgn = [
        game(
          white: 'me',
          black: 'a',
          date: '2026.06.01',
          tc: '300',
          link: 'https://lichess.org/abc',
        ),
        game(
          white: 'me',
          black: 'a',
          date: '2026.06.01',
          tc: '300',
          link: 'https://lichess.org/abc',
        ),
      ].join('\n\n');

      final kept = applySelection(parseGameRecords(pgn), const GameSelection());
      expect(kept.length, 1);
    });
  });

  group('applySelectionUnion', () {
    test('keeps a game when any selection keeps it, de-duplicated and '
        'newest first', () {
      final pgn = [
        game(white: 'w1', black: 'a', date: '2026.08.04', tc: '300'),
        game(white: 'w2', black: 'b', date: '2026.08.03', tc: '300'),
        game(white: 'w3', black: 'c', date: '2026.08.01', tc: '300'),
      ].join('\n\n');
      final records = parseGameRecords(pgn);

      final union = applySelectionUnion(records, [
        // Newest one game — keeps w1.
        const GameSelection(maxGames: 1, speeds: {}),
        // Since Aug 3 — keeps w1 (again) and w2.
        GameSelection(since: DateTime.utc(2026, 8, 3), speeds: const {}),
      ]);

      expect([for (final r in union) r.white], ['w1', 'w2']);
    });

    test('a single selection matches applySelection exactly', () {
      final pgn = [
        game(white: 'w1', black: 'a', date: '2026.08.04', tc: '300'),
        game(white: 'w2', black: 'b', date: '2026.08.03', tc: '60'),
      ].join('\n\n');
      final records = parseGameRecords(pgn);
      const selection = GameSelection(speeds: {GameSpeed.blitz});

      expect(
        [
          for (final r in applySelectionUnion(records, [selection])) r.dedupKey,
        ],
        [for (final r in applySelection(records, selection)) r.dedupKey],
      );
    });
  });
}
