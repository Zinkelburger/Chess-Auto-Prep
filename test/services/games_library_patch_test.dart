/// The auto-analysis write path: patch one game's movetext into a cache file
/// by dedup key, leaving its headers and every other game byte-identical.
library;

import 'dart:io';

import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _gameA =
    '[Event "Rated blitz game"]\n'
    '[Site "https://lichess.org/abc12345"]\n'
    '[White "me"]\n'
    '[Black "them"]\n'
    '[Result "1-0"]\n'
    '\n'
    '1. e4 { [%clk 0:03:00] } e5 2. Nf3 1-0\n';

const _gameB =
    '[Event "Rated blitz game"]\n'
    '[Site "https://lichess.org/def45678"]\n'
    '[White "them2"]\n'
    '[Black "me"]\n'
    '[Result "0-1"]\n'
    '\n'
    '1. d4 d5 2. c4 0-1\n';

void main() {
  late Directory dir;
  late File cache;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('games_patch_test');
    cache = File('${dir.path}/lichess_me.pgn');
    await cache.writeAsString('$_gameA\n$_gameB');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('patches the matching game and preserves the other verbatim', () async {
    const annotated =
        '1. d4 { [%eval 0.2,18] } d5 { [%eval 0.1,18] } '
        '2. c4 { [%eval 0.3,18] } 0-1';
    final ok = await GamesLibraryService.patchGameMovetext(
      cachePath: cache.path,
      dedupKey: 'https://lichess.org/def45678',
      updatedMovetext: annotated,
    );
    expect(ok, isTrue);

    final content = await cache.readAsString();
    final games = splitPgnIntoGames(content);
    expect(games, hasLength(2));
    // Untouched game keeps its exact text (headers, clock comment, all).
    expect(games[0].trim(), _gameA.trim());
    // Patched game keeps its headers but carries the new movetext.
    expect(games[1], contains('[Site "https://lichess.org/def45678"]'));
    expect(games[1], contains('[%eval 0.2,18]'));
    expect(games[1], isNot(contains('1. d4 d5 2. c4 0-1')));
    // The file still parses into records with the same identities.
    final records = parseGameRecords(content);
    expect(records.map((r) => r.dedupKey).toSet(), {
      'https://lichess.org/abc12345',
      'https://lichess.org/def45678',
    });
  });

  test('a batch patches every named game in one write', () async {
    // The review runner finishes games one at a time but writes once: a patch
    // per game would rewrite the whole cache file once per game.
    final patched = await GamesLibraryService.patchGameMovetexts(
      cachePath: cache.path,
      movetextByDedupKey: {
        'https://lichess.org/abc12345':
            '1. e4 { [%eval 0.3,18] } e5 2. Nf3 1-0',
        'https://lichess.org/def45678': '1. d4 { [%eval 0.2,18] } d5 0-1',
        // Named but not in this file — skipped, not an error.
        'https://lichess.org/ghi78901': '1. c4 1/2-1/2',
      },
    );
    expect(patched, 2);

    final games = splitPgnIntoGames(await cache.readAsString());
    expect(games, hasLength(2));
    expect(games[0], contains('[%eval 0.3,18]'));
    expect(games[0], contains('[Site "https://lichess.org/abc12345"]'));
    expect(games[1], contains('[%eval 0.2,18]'));
    expect(games[1], contains('[Site "https://lichess.org/def45678"]'));
  });

  test('a batch that matches nothing leaves the file alone', () async {
    final before = await cache.readAsString();
    expect(
      await GamesLibraryService.patchGameMovetexts(
        cachePath: cache.path,
        movetextByDedupKey: {'https://lichess.org/nope': '1. e4'},
      ),
      0,
    );
    expect(await cache.readAsString(), before);
    expect(
      await GamesLibraryService.patchGameMovetexts(
        cachePath: cache.path,
        movetextByDedupKey: const {},
      ),
      0,
    );
    expect(await cache.readAsString(), before);
  });

  test('returns false for an unknown game or missing file', () async {
    expect(
      await GamesLibraryService.patchGameMovetext(
        cachePath: cache.path,
        dedupKey: 'https://lichess.org/nope',
        updatedMovetext: '1. e4',
      ),
      isFalse,
    );
    expect(
      await GamesLibraryService.patchGameMovetext(
        cachePath: '${dir.path}/missing.pgn',
        dedupKey: 'https://lichess.org/abc12345',
        updatedMovetext: '1. e4',
      ),
      isFalse,
    );
    // And the file was not rewritten.
    expect(await cache.readAsString(), '$_gameA\n$_gameB');
  });
}
