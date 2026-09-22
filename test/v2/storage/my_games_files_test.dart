// What the review of the user's games writes, through the real store: the
// puzzles and the analysed-games line into the tactics set, and the games
// into the old app's cache.
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/chess/tactics/analyzed_games.dart';
import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/chess/tactics/mined_set.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/my_games_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/my_games_fixture.dart';
import '../support/tactics_fixture.dart';
import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;

  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  group('the tactics set', () {
    test('takes the puzzles and the new analysed-games line in one save, '
        'every game before them as it was', () async {
      final ref = fixture.ref('tactics_sets/Default.pgn');
      final revision = await fixture.put(ref, tacticsSet);
      final set = parseChapter(name: 'Default', text: tacticsSet);
      final edit =
          withMined(
                set,
                [minedScholarsMate()],
                analyzed: {'lichess_abc', 'lichess_AbCd1234'},
              )
              as ChapterEdited;

      final saved = await fixture.store.save(
        ref,
        writeChapter(edit.chapter),
        expected: revision,
        scope: GamesRearranged(edit.games),
      );

      expect(saved, isA<Saved>());
      final text = await File(ref.path).readAsString();
      expect(analyzedIn(text), {'lichess_abc', 'lichess_AbCd1234'});
      expect(text, endsWith('$scholarsMatePuzzle\n'));
    });

    test('refuses a heading edit that changes more than that line', () async {
      final ref = fixture.ref('tactics_sets/Default.pgn');
      final revision = await fixture.put(ref, tacticsSet);
      final changed = tacticsSet.replaceFirst(
        '[Event "Default #1"]',
        '// a note\n[Event "Default #1"]',
      );

      final saved = await fixture.store.save(
        ref,
        withAnalyzed(changed, {'x'}),
        expected: revision,
        scope: GamesRearranged(
          GamesArranged(order: [0, 1, 2, 3, 4], before: 5, heading: true),
        ),
      );

      expect(saved, isA<SaveRefused>());
      expect(await File(ref.path).readAsString(), tacticsSet);
    });
  });

  group('the games cache', () {
    late GamesCache cache;
    setUp(
      () => cache = GamesCache(
        fixture.store,
        folder: p.join(fixture.documents.path, 'games_library'),
      ),
    );

    test('is the old app\'s file, named by site and username', () {
      expect(
        p.basename(cache.refFor(GameSite.chesscom, 'Big.Man').path),
        'chesscom_big_man.pgn',
      );
    });

    test('keeps new games at the end, once each, with when they came '
        'down', () async {
      final when = DateTime(2026, 9, 22, 10);
      await cache.keep(GameSite.lichess, 'me', [scholarsMate], when);
      await cache.keep(GameSite.lichess, 'me', [
        quietChesscomGame,
        scholarsMate,
      ], when);

      final ref = cache.refFor(GameSite.lichess, 'me');
      final text = await File(ref.path).readAsString();
      expect(text, '$scholarsMate\n\n$quietChesscomGame\n');
      expect(
        await File('${ref.path}.fetched').readAsString(),
        '${when.millisecondsSinceEpoch}',
      );
    });

    test('answers the newest saved games first, and nothing when there '
        'are none', () async {
      expect(await cache.read(GameSite.lichess, 'me', max: 5), isNull);
      await cache.keep(GameSite.lichess, 'me', [
        quietChesscomGame,
        scholarsMate,
      ], DateTime(2026));

      final saved = await cache.read(GameSite.lichess, 'me', max: 5);
      expect(saved, [scholarsMate, quietChesscomGame]);
      expect(await cache.read(GameSite.lichess, 'me', max: 1), [scholarsMate]);
    });
  });

  test('the old app\'s separate list of analysed games is read', () async {
    expect(await readOlderAnalyzed(fixture.documents), isEmpty);
    await File(
      p.join(fixture.documents.path, 'analyzed_games.txt'),
    ).writeAsString('lichess_a\n\nchesscom_1\n');
    expect(await readOlderAnalyzed(fixture.documents), {
      'lichess_a',
      'chesscom_1',
    });
  });
}
