import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/game_filter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/reading_place.dart';
import 'package:chess_auto_prep/v2/storage/pgn_export.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/viewer_fixture.dart';

const collection = '''
[Event "First"]
[White "Alice"]
[Result "*"]

1. Nf3 Nf6 2. g3 g6 {Keep this note} 3. Bg2 (3. d3) Bg7 *

[Event "Transposition"]
[White "Bob"]
[Result "*"]

1. g3 g6 2. Nf3 Nf6 3. Bg2 Bg7 *

[Event "Different"]
[White "Alice"]
[Result "*"]

1. e4 e5 *
''';

Future<void> filtered(ViewerFixture f) async {
  for (var i = 0; i < 500 && f.filter.busy; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(f.filter.busy, isFalse);
  expect(f.filter.problem, isNull);
}

void main() {
  test(
    'captured position finds transpositions and exports complete games',
    () async {
      final folder = await Directory.systemTemp.createTemp('position-export-');
      addTearDown(() => folder.delete(recursive: true));
      final f = await viewerOver(
        collection,
        exporter: PgnExport(pickDirectory: () async => folder.path),
      );
      addTearDown(f.dispose);
      await f.open();
      f.session.goTo(NodePath.of([0, 0, 0, 0]));
      final target = f.session.fen;
      f.filter.reachingBoardPosition();
      expect(
        f.viewer.exportText(),
        isNull,
        reason: 'no stale export during filtering',
      );
      f.session.toStart();
      await filtered(f);
      expect(f.viewer.gameOrder, [0, 1]);
      expect(f.filter.applied.position, target);
      f.viewer.showGame(1);
      expect(f.session.fen.position, target.position);
      final text = f.viewer.exportText()!;
      expect(text, contains('Keep this note'));
      expect(text, contains('(3. d3)'));
      expect(text, contains('3. Bg2 Bg7'));
      expect(text, isNot(contains('Different')));
      expect(await f.viewer.export('matching.pgn', text), isA<PgnExported>());
      expect(await File('${folder.path}/matching.pgn').readAsString(), text);
      expect(f.onDisk, collection);
      f.filter.apply(
        f.filter.filter.copyWith(rules: const [HeaderRule(value: 'Alice')]),
      );
      await filtered(f);
      expect(f.viewer.gameOrder, [0]);
      final saved = ReadingPlace(
        game: 0,
        key: 'game',
        path: f.session.cursor,
        sort: f.viewer.sort,
        filter: f.filter.filter,
      );
      expect(
        ReadingPlace.decode(jsonEncode(saved.json))!.filter,
        f.filter.filter,
      );
      f.filter.apply(GameFilter.none);
      expect(f.viewer.gameOrder, [0, 1, 2]);
    },
  );

  test(
    'position matching includes roots and late moves, ignores counters and sidelines',
    () async {
      final moves = List.filled(15, 'Nf3 Nf6 Ng1 Ng8').join(' ');
      final f = await viewerOver('''
[Event "Late"]

$moves e4 *

[Event "Sideline only"]

1. d4 (1. e4) d5 *

[Event "Setup"]
[SetUp "1"]
[FEN "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 7 90"]

90... c5 *
''');
      addTearDown(f.dispose);
      await f.open();
      f.session.toEnd();
      final position = f.session.fen;
      expect(f.session.cursor.indexes.length, 61);
      f.filter.reaching(position);
      await filtered(f);
      expect(f.viewer.gameOrder, [0, 2]);
      f.filter.reaching(Fen(position.value.replaceFirst(' KQkq ', ' - ')));
      await filtered(f);
      expect(f.viewer.gameOrder, isEmpty, reason: 'castling rights matter');
      f.filter.reaching(position);
      f.filter.apply(GameFilter.none);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(f.viewer.gameOrder, [
        0,
        1,
        2,
      ], reason: 'cancelled search cannot return later');
    },
  );
}
