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
            link: 'https://lichess.org/abc'),
        game(
            white: 'me',
            black: 'a',
            date: '2026.06.01',
            tc: '300',
            link: 'https://lichess.org/abc'),
      ].join('\n\n');

      final kept = applySelection(parseGameRecords(pgn), const GameSelection());
      expect(kept.length, 1);
    });
  });
}
