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
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
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

    test('native refused corpus write does not publish freshness', () async {
      final ref = cache.refFor(GameSite.lichess, 'me');
      await Directory(ref.path).create(recursive: true);
      expect(
        await cache.keep(GameSite.lichess, 'me', [
          scholarsMate,
        ], DateTime(2026)),
        isA<GamesNotKept>(),
      );
      expect(await File('${ref.path}.fetched').exists(), isFalse);
    });

    test(
      'stamp failure retains published corpus for independent restart and retry',
      () async {
        final ref = cache.refFor(GameSite.lichess, 'me');
        final obstruction = Directory('${ref.path}.fetched');
        await obstruction.create(recursive: true);
        final when = DateTime(2026);
        expect(
          await cache.keep(GameSite.lichess, 'me', [
            scholarsMate,
            scholarsMate,
          ], when),
          isA<GamesNotKept>(),
        );
        final reopened = GamesCache(fixture.store, folder: cache.folder);
        expect(await reopened.all(GameSite.lichess, 'me'), [scholarsMate]);
        await obstruction.delete();
        expect(
          await reopened.keep(GameSite.lichess, 'me', [scholarsMate], when),
          isA<GamesKept>(),
        );
        expect(await reopened.all(GameSite.lichess, 'me'), [scholarsMate]);
        expect(
          await File('${ref.path}.fetched').readAsString(),
          '${when.millisecondsSinceEpoch}',
        );
      },
    );

    test('unrecognized fetched staging link preserves its target', () async {
      final ref = cache.refFor(GameSite.lichess, 'me');
      await Directory(cache.folder).create(recursive: true);
      final outside = File(p.join(fixture.root.path, 'unrelated'));
      await outside.writeAsString('unrelated bytes');
      final stage = Link(
        p.join(cache.folder, '.${p.basename(ref.path)}.fetched.v2-tmp'),
      );
      await stage.create(outside.path);
      expect(
        await cache.keep(GameSite.lichess, 'me', [
          scholarsMate,
        ], DateTime(2026)),
        isA<GamesNotKept>(),
      );
      expect(await outside.readAsString(), 'unrelated bytes');
      expect(await stage.target(), outside.path);
    });

    for (final existing in [false, true]) {
      test(
        'lost ${existing ? 'append' : 'create'} acknowledgement retries native corpus exactly once',
        () async {
          final ref = cache.refFor(GameSite.lichess, 'me');
          if (existing) {
            await cache.keep(GameSite.lichess, 'me', [
              quietChesscomGame,
            ], DateTime(2025));
          }
          final flaky = GamesCache(
            _LostAcknowledgement(fixture.store),
            folder: cache.folder,
          );
          expect(
            await flaky.keep(GameSite.lichess, 'me', [
              scholarsMate,
            ], DateTime(2026)),
            isA<GamesNotKept>(),
          );
          final beforeRetry = await File(ref.path).readAsString();
          expect(
            await flaky.keep(GameSite.lichess, 'me', [
              scholarsMate,
            ], DateTime(2026)),
            isA<GamesKept>(),
          );
          expect(await File(ref.path).readAsString(), beforeRetry);
          expect(
            await cache.all(GameSite.lichess, 'me'),
            existing ? [quietChesscomGame, scholarsMate] : [scholarsMate],
          );
        },
      );
    }

    test(
      'distinct games without site identifiers survive keep and exact retry',
      () async {
        const first = '[Event "First"]\n[Result "*"]\n\n1. e4 *';
        const second = '[Event "Second"]\n[Result "*"]\n\n1. d4 *';
        expect(
          await cache.keep(GameSite.lichess, 'me', [
            first,
            second,
          ], DateTime(2026)),
          isA<GamesKept>(),
        );
        expect(await cache.all(GameSite.lichess, 'me'), [first, second]);
        expect(
          await cache.keep(GameSite.lichess, 'me', [
            first,
            second,
          ], DateTime(2026)),
          isA<GamesKept>(),
        );
        expect(await cache.all(GameSite.lichess, 'me'), [first, second]);
      },
    );

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

    test('a file of hundreds of games reads the same, newest first, and '
        'takes only the games it does not have', () async {
      String two(int n) => '$n'.padLeft(2, '0');
      // Game i is played i seconds after ten o'clock.
      String game(int i) =>
          '[Event "Rated blitz game"]\n'
          '[Site "https://lichess.org/${'g$i'.padLeft(8, '0')}"]\n'
          '[UTCDate "2026.09.20"]\n'
          '[UTCTime "10:${two(i ~/ 60)}:${two(i % 60)}"]\n'
          '[White "Me"]\n[Black "Other"]\n[Result "*"]\n\n'
          '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 *';
      final many = [for (var i = 0; i < 400; i++) game(i)];
      expect(many.join('\n\n').length, greaterThan(64 * 1024));
      final when = DateTime(2026, 9, 22);
      await cache.keep(GameSite.lichess, 'me', many, when);
      await cache.keep(GameSite.lichess, 'me', [game(399), game(400)], when);

      final all = await cache.all(GameSite.lichess, 'me');
      expect(all, hasLength(401));
      expect(all!.last, game(400));
      final newest = await cache.newest(GameSite.lichess, 'me', max: 3);
      expect([for (final g in newest!) g.index], [400, 399, 398]);
      expect(newest.first.text, game(400));
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

  test('a list of analysed games that cannot be read is no answer, not '
      'an empty one', () async {
    await File(
      p.join(fixture.documents.path, 'analyzed_games.txt'),
    ).writeAsBytes([0x6c, 0x69, 0xff, 0xfe, 0x0a]);
    expect(await readOlderAnalyzed(fixture.documents), isNull);
  });
}

/// The native publication lands, but the caller receives no acknowledgement.
final class _LostAcknowledgement implements PgnDocumentStore {
  _LostAcknowledgement(this.store);
  final PgnDocumentStore store;
  bool lose = true;
  @override
  Future<DocumentRead> open(DocumentRef ref) => store.open(ref);
  @override
  Future<CreateResult> create(DocumentRef ref, String text) async {
    final result = await store.create(ref, text);
    if (lose && result is Created) {
      lose = false;
      return const IoFailure('acknowledgement lost');
    }
    return result;
  }

  @override
  Future<SaveResult> save(
    DocumentRef ref,
    String text, {
    required Revision expected,
    required EditScope scope,
  }) async {
    final result = await store.save(
      ref,
      text,
      expected: expected,
      scope: scope,
    );
    if (lose && result is Saved) {
      lose = false;
      return const IoFailure('acknowledgement lost');
    }
    return result;
  }

  @override
  Never noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
