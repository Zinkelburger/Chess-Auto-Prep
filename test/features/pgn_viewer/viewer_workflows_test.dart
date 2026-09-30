import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/chess/game_filter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/game_order.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/reading_place.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/pgn_export.dart';
import 'package:chess_auto_prep/storage/viewer_places.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/scripted_store.dart';
import '../../support/viewer_fixture.dart';

final class Places implements ViewerPlaces {
  final saved = <String, ReadingPlace>{};
  Completer<void>? writing;
  bool fail = false;
  @override
  Future<ReadingPlace?> load(String path) async => saved[path];
  @override
  Future<void> save(String path, ReadingPlace place) async {
    await writing?.future;
    if (fail) throw StateError('disk offline');
    saved[path] = place;
  }
}

void main() {
  test(
    'sorting and navigation follow filtered games, preserving file indices',
    () async {
      final f = await viewerOver(threeGameFile);
      addTearDown(f.dispose);
      await f.open();
      f.viewer.sortBy(GameOrder.dateDesc);
      expect(f.viewer.gameOrder, [1, 0, 2]);
      f.viewer.showGame(1);
      f.viewer.walk(1);
      expect(f.session.game, 0);
      f.filter.apply(
        const GameFilter(
          rules: [HeaderRule(field: 'Event', value: 'Tata')],
        ),
      );
      expect(f.viewer.gameOrder, [1, 0]);
      f.viewer.walk(1);
      expect(f.session.game, 0);
      f.viewer.walk(-1);
      expect(f.session.game, 1);
      expect(f.onDisk, threeGameFile);
    },
  );
  test(
    'export snapshots visible draft and cannot replace an existing export',
    () async {
      final folder = await Directory.systemTemp.createTemp('viewer-export-');
      addTearDown(() => folder.delete(recursive: true));
      final picker = Completer<String?>();
      final f = await viewerOver(
        threeGameFile,
        exporter: PgnExport(pickDirectory: () => picker.future),
      );
      addTearDown(f.dispose);
      await f.open();
      f.viewer.search('Ding');
      final text = f.viewer.exportText()!;
      final exporting = f.viewer.export('visible.pgn', text);
      f.viewer.search('Carlsen');
      picker.complete(folder.path);
      expect(await exporting, isA<PgnExported>());
      expect(await File('${folder.path}/visible.pgn').readAsString(), text);
      expect(text, contains('Ding'));
      expect(text, isNot(contains('Carlsen')));
      expect(
        await f.viewer.export('visible.pgn', 'other'),
        isA<PgnExportFailed>(),
      );
      expect(f.onDisk, threeGameFile);
    },
  );
  test(
    'reading restores game identity, cursor, sorting and filters after reordering',
    () async {
      final places = Places();
      final f = await viewerOver(threeGameFile, places: places);
      addTearDown(f.dispose);
      await f.open();
      f.viewer.showGame(1);
      f.session.goTo(NodePath.of([0, 0]));
      f.viewer.sortBy(GameOrder.dateDesc);
      f.filter.apply(
        const GameFilter(
          rules: [HeaderRule(field: 'Event', value: 'Tata')],
        ),
      );
      await f.viewer.pendingWrites.settle();
      final place = await f.viewer.savedPlace(f.ref);
      expect(place!.game, 1);
      final lines = f.session.chapter!.lines;
      final reordered = [
        lines[1].text,
        lines[0].text,
        lines[2].text,
      ].join('\n\n');
      f.session.closed();
      f.viewer.closed();
      f.store.documents[f.ref] = Opened(reordered, scriptedRevision(reordered));
      await f.session.open(f.ref, game: 0);
      await f.viewer.opened(f.ref, place: place);
      expect(f.session.game, 0);
      expect(f.session.cursor, NodePath.of([0, 0]));
      expect(f.viewer.sort, GameOrder.dateDesc);
      expect(f.filter.kept, 2);
      expect(f.onDisk, reordered);
    },
  );
  test(
    'failed reading checkpoint is retained through disposal and exact retry',
    () async {
      final places = Places()..fail = true;
      final f = await viewerOver(threeGameFile, places: places);
      await f.open();
      f.viewer.showGame(1);
      f.session.goTo(NodePath.of([0]));
      expect(
        await f.viewer.pendingWrites.settle(),
        contains('Reading position'),
      );
      f.dispose();
      places.fail = false;
      await f.viewer.retryReading();
      expect(await f.viewer.pendingWrites.settle(), isNull);
      expect(places.saved[f.ref.path]!.game, 1);
      expect(places.saved[f.ref.path]!.path, NodePath.of([0]));
    },
  );
  test(
    'a restored empty slice clears; an unmatched identity does not select another game',
    () async {
      final f = await viewerOver(threeGameFile, places: Places());
      addTearDown(f.dispose);
      await f.session.open(f.ref, game: 0);
      await f.viewer.opened(
        f.ref,
        place: ReadingPlace(
          game: 1,
          key: 'no longer present',
          path: NodePath.of([0]),
          sort: GameOrder.ratingDesc,
          filter: const GameFilter(rules: [HeaderRule(value: 'Nobody')]),
        ),
      );
      expect(f.session.game, 0);
      expect(f.session.cursor.isRoot, isTrue);
      expect(f.filter.kept, 3);
    },
  );
  test(
    'rating order is stable and unknown ratings are last in either direction',
    () async {
      final chapter = await readChapter(
        name: '',
        text:
            '[Event "A"]\n[WhiteElo "2000"]\n[BlackElo "2400"]\n\n*\n\n[Event "B"]\n\n*\n\n[Event "C"]\n[WhiteElo "2200"]\n\n*\n\n[Event "D"]\n[WhiteElo "1800"]\n\n*',
      );
      expect(orderGames(chapter.lines, [0, 1, 2, 3], GameOrder.ratingDesc), [
        0,
        2,
        3,
        1,
      ]);
      expect(orderGames(chapter.lines, [0, 1, 2, 3], GameOrder.ratingAsc), [
        3,
        0,
        2,
        1,
      ]);
    },
  );
}
