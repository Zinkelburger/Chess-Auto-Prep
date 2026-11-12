import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/finds.dart';
import 'package:chess_auto_prep/storage/finds_store.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const _find = Find(
  kind: FindKind.trap,
  sans: ['e4', 'e5'],
  ply: 2,
  keyPly: 1,
  fen: Fen('8/8/8/8/8/8/8/K6k w - - 0 1'),
  evalCp: 100,
  lossCp: 200,
  share: 0.3,
  reach: 0.5,
  worth: 1,
);

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('finds-'));
  tearDown(() => root.delete(recursive: true));

  bool keep(FindsStore store) => store.keep(
    const [_find],
    side: Side.white,
    rootFen: Fen.initial,
    elo: 1800,
    at: DateTime.utc(2026, 11, 12),
  );

  test('a Support folder not made yet is made, parents and all', () {
    final store = FindsStore.open(Directory(p.join(root.path, 'a', 'b')));
    addTearDown(store.close);
    expect(store.available, isTrue);
    expect(keep(store), isTrue);
    expect(store.all(), hasLength(1));
  });

  test('finds another program\'s lock refuses are not reported kept', () {
    final store = FindsStore.open(root);
    addTearDown(store.close);
    final other = sqlite3.open(p.join(root.path, 'finds.db'))
      ..execute('BEGIN EXCLUSIVE');
    addTearDown(other.close);
    expect(keep(store), isFalse);
    other.execute('COMMIT');
    expect(store.all(), isEmpty);
    expect(keep(store), isTrue);
  });
}
