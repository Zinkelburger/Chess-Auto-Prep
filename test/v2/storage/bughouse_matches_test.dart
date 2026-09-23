import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/bughouse/match.dart';
import 'package:chess_auto_prep/v2/storage/bughouse_matches.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory documents;
  late String root;
  late MatchFolder store;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('v2-matches-');
    root = p.join(documents.path, 'bughouse_matches');
    store = MatchFolder(root);
  });

  tearDown(() => documents.delete(recursive: true));

  final config = MatchConfig(
    name: 'e4 e5!',
    startDualFen:
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1|'
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1',
    seed: 7,
  );

  test('a new match is a folder named after it, never over another', () async {
    final first = await store.create(config, DateTime(2026, 9, 23));
    final second = await store.create(config, DateTime(2026, 9, 24));
    expect((first as MatchCreated).match.id, 'e4-e5');
    expect((second as MatchCreated).match.id, 'e4-e5-2');
    final listed = await store.list();
    expect(listed.map((m) => m.id), ['e4-e5-2', 'e4-e5']);
    expect(listed.first.status, MatchStatus.pending);
  });

  test('saving writes match.json and games.bpgn, both readable', () async {
    final created =
        (await store.create(config, DateTime(2026))) as MatchCreated;
    final game = (
      number: 1,
      whiteIndex: 0,
      blackIndex: 1,
      whiteName: 'Hivemind A',
      blackName: 'Hivemind B',
      result: MatchResult.whiteWins,
      ending: MatchEnding.checkmate,
      detail: 'board 2',
      moves: ['1e2e4', '2d2d4'],
      startedAt: DateTime(2026),
      durationMs: 10,
    );
    final saved = created.match.copyWith(
      status: MatchStatus.completed,
      games: [game],
    );
    expect(await store.save(saved), isNull);
    final json = jsonDecode(
      await File(p.join(root, 'e4-e5', 'match.json')).readAsString(),
    );
    // The keys the old app's reader looks for.
    expect(
      (json as Map).keys,
      containsAll(['version', 'id', 'config', 'games']),
    );
    expect(json['status'], 'completed');
    final bpgn = await File(p.join(root, 'e4-e5', 'games.bpgn')).readAsString();
    expect(bpgn, contains('1A. e4 1B. d4'));
    final again = (await store.list()).single;
    expect(again.games.single.moves, ['1e2e4', '2d2d4']);
  });

  test('a damaged match hides itself, not the list', () async {
    await store.create(config, DateTime(2026));
    await Directory(p.join(root, 'broken')).create();
    await File(p.join(root, 'broken', 'match.json')).writeAsString('{nope');
    expect((await store.list()).map((m) => m.id), ['e4-e5']);
  });

  test('delete moves the folder to .trash, which the list skips', () async {
    await store.create(config, DateTime(2026));
    expect(await store.delete('e4-e5'), isNull);
    expect(await store.list(), isEmpty);
    final trash = Directory(p.join(root, '.trash'));
    expect(await trash.list().length, 1);
  });

  test('a folder that cannot be made is said, and nothing is kept', () async {
    // A file where the matches folder should be.
    await File(root).writeAsString('in the way');
    final made = await store.create(config, DateTime(2026));
    expect(made, isA<MatchCreateFailed>());
    expect(await store.list(), isEmpty);
  });
}
