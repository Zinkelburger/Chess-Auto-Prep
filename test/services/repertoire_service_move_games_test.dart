import 'dart:io';

import 'package:chess_auto_prep/services/repertoire_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Moving games between chapter files and reordering them within one — the
/// primitives a drag in the outline turns into — and the exact-index insert
/// that makes each of them undoable.
String _game(String event) =>
    '[Event "$event"]\n[Result "*"]\n\n1. e4 e6 2. d4 d5 *\n';

Future<List<String>> _events(RepertoireService s, String path) async =>
    (await s.readPgnDocument(path))!.games
        .map((g) => RegExp(r'\[Event "([^"]*)"\]').firstMatch(g)!.group(1)!)
        .toList();

void main() {
  late Directory tmp;
  late String a;
  late String b;
  final service = RepertoireService();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('move_games_test');
    a = p.join(tmp.path, 'A.pgn');
    b = p.join(tmp.path, 'B.pgn');
    File(a).writeAsStringSync(
      '// Color: Black\n\n${['a0', 'a1', 'a2', 'a3', 'a4'].map(_game).join('\n')}',
    );
    File(
      b,
    ).writeAsStringSync('// Color: Black\n\n${_game('b0')}\n${_game('b1')}');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('insertGameTextsAt lands each game at its final index', () async {
    await service.insertGameTextsAt(b, [
      (index: 3, text: _game('x3')),
      (index: 0, text: _game('x0')),
    ]);
    expect(await _events(service, b), ['x0', 'b0', 'b1', 'x3']);
  });

  test('insertGameTextsAt creates a missing file', () async {
    final c = p.join(tmp.path, 'C.pgn');
    await service.insertGameTextsAt(c, [(index: 5, text: _game('c'))]);
    expect(await _events(service, c), ['c']);
  });

  group('moveGamesTo', () {
    test('reorders within a file: before the game at toIndex', () async {
      final landed = await service.moveGamesTo(
        fromPath: a,
        gameIndexes: {0, 3},
        toPath: a,
        toIndex: 2,
      );
      expect(landed, [1, 2]);
      expect(await _events(service, a), ['a1', 'a0', 'a3', 'a2', 'a4']);
    });

    test('reorders to the end when toIndex is null', () async {
      final landed = await service.moveGamesTo(
        fromPath: a,
        gameIndexes: {1},
        toPath: a,
      );
      expect(landed, [4]);
      expect(await _events(service, a), ['a0', 'a2', 'a3', 'a4', 'a1']);
    });

    test('moves across files as a block at toIndex', () async {
      final landed = await service.moveGamesTo(
        fromPath: a,
        gameIndexes: {4, 1},
        toPath: b,
        toIndex: 1,
        transform: (i, text) => text.replaceFirst('[Event "', '[Event "moved-'),
      );
      expect(landed, [1, 2]);
      expect(await _events(service, a), ['a0', 'a2', 'a3']);
      expect(await _events(service, b), ['b0', 'moved-a1', 'moved-a4', 'b1']);
    });

    test('a cross-file move undoes exactly with toIndexes', () async {
      final landed = await service.moveGamesTo(
        fromPath: a,
        gameIndexes: {0, 2, 4},
        toPath: b,
      );
      expect(landed, [2, 3, 4]);
      final back = await service.moveGamesTo(
        fromPath: b,
        gameIndexes: landed.toSet(),
        toPath: a,
        toIndexes: [0, 2, 4],
      );
      expect(back, [0, 2, 4]);
      expect(await _events(service, a), ['a0', 'a1', 'a2', 'a3', 'a4']);
      expect(await _events(service, b), ['b0', 'b1']);
    });

    test('a reorder undoes exactly with toIndexes', () async {
      final landed = await service.moveGamesTo(
        fromPath: a,
        gameIndexes: {1, 2},
        toPath: a,
        toIndex: 5,
      );
      expect(landed, [3, 4]);
      await service.moveGamesTo(
        fromPath: a,
        gameIndexes: landed.toSet(),
        toPath: a,
        toIndexes: [1, 2],
      );
      expect(await _events(service, a), ['a0', 'a1', 'a2', 'a3', 'a4']);
    });

    test('returns nothing for indexes the file does not have', () async {
      expect(
        await service.moveGamesTo(fromPath: a, gameIndexes: {9}, toPath: b),
        isEmpty,
      );
      expect(await _events(service, b), ['b0', 'b1']);
    });
  });
}
