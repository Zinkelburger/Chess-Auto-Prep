import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:flutter_test/flutter_test.dart';

/// The games-library cache must merge fresh downloads instead of overwriting:
/// cached games carry locally written `[%eval]` annotations from the PGN
/// viewer's review pass, and a TTL refresh must never destroy them.
void main() {
  String game({
    required String link,
    required String moves,
    String white = 'me',
    String black = 'them',
  }) =>
      '[Event "Live Chess"]\n'
      '[White "$white"]\n'
      '[Black "$black"]\n'
      '[Link "$link"]\n'
      '[Result "1-0"]\n'
      '\n'
      '$moves 1-0';

  test('appends only genuinely new games, keeping existing order', () {
    final existing =
        '${game(link: 'https://x/1', moves: '1. e4 e5')}\n\n'
        '${game(link: 'https://x/2', moves: '1. d4 d5')}';
    final fresh =
        '${game(link: 'https://x/2', moves: '1. d4 d5')}\n\n'
        '${game(link: 'https://x/3', moves: '1. c4 c5')}';

    final merged = mergeGamePgns(existing: existing, fresh: fresh);
    final records = parseGameRecords(merged);
    expect(records, hasLength(3));
    expect(
      merged.indexOf('https://x/1'),
      lessThan(merged.indexOf('https://x/3')),
    );
  });

  test('keeps the existing text of a re-downloaded game verbatim', () {
    // The cached copy has been annotated by a review pass.
    final annotated = game(
      link: 'https://x/1',
      moves: '1. e4 { [%eval 0.31] } 1... e5 { [%eval 0.29] }',
    );
    final plain = game(link: 'https://x/1', moves: '1. e4 e5');

    final merged = mergeGamePgns(existing: annotated, fresh: plain);
    expect(merged, contains('[%eval 0.31]'));
    expect(parseGameRecords(merged), hasLength(1));
  });

  test('an empty cache just takes the fresh download', () {
    final fresh = game(link: 'https://x/1', moves: '1. e4 e5');
    final merged = mergeGamePgns(existing: '', fresh: fresh);
    expect(parseGameRecords(merged), hasLength(1));
  });

  test('no new games returns the existing content unchanged', () {
    final existing = game(link: 'https://x/1', moves: '1. e4 e5');
    final merged = mergeGamePgns(existing: existing, fresh: existing);
    expect(merged, existing);
  });

  test('maxGames drops the oldest games and keeps file order', () {
    String dated(String link, String date) =>
        '[Event "Live Chess"]\n'
        '[White "me"]\n'
        '[Black "them"]\n'
        '[Link "$link"]\n'
        '[UTCDate "$date"]\n'
        '[Result "1-0"]\n'
        '\n'
        '1. e4 e5 1-0';

    // Oldest first in the file, so the cap has to drop from the front.
    final existing = [
      dated('https://x/old', '2026.01.01'),
      dated('https://x/mid', '2026.02.01'),
    ].join('\n\n');
    final fresh = dated('https://x/new', '2026.03.01');

    final merged = mergeGamePgns(existing: existing, fresh: fresh, maxGames: 2);
    final records = parseGameRecords(merged);
    expect(records, hasLength(2));
    expect(merged, isNot(contains('https://x/old')));
    expect(
      merged.indexOf('https://x/mid'),
      lessThan(merged.indexOf('https://x/new')),
      reason: 'survivors keep the order they already had',
    );
  });

  test('maxGames leaves an under-cap merge untouched', () {
    final existing = game(link: 'https://x/1', moves: '1. e4 e5');
    final merged = mergeGamePgns(
      existing: existing,
      fresh: game(link: 'https://x/2', moves: '1. d4 d5'),
      maxGames: 10,
    );
    expect(parseGameRecords(merged), hasLength(2));
    expect(merged, startsWith(existing.trimRight()));
  });

  test('games without links dedupe by players and date', () {
    const headers =
        '[White "a"]\n[Black "b"]\n[UTCDate "2026.07.28"]\n[UTCTime "10:00:00"]\n';
    const g = '[Event "e"]\n$headers\n1. e4 e5 *';
    final merged = mergeGamePgns(existing: g, fresh: g);
    expect(parseGameRecords(merged), hasLength(1));
  });
}
