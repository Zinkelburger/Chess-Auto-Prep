import 'dart:async';

import 'package:chess_auto_prep/core/pgn_viewer_controller.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/services/game_analysis_controller.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart' as pgn;
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Analysis extends GameAnalysisController {
  @override
  Future<bool> tryLoadFromPgn(String pgnText) async => false;

  @override
  void cancel() {}
}

class _MemoryStorage extends IOStorageService {
  _MemoryStorage(this.content);

  String content;

  @override
  Future<String> updateFile(
    String path,
    FutureOr<String> Function(String?) update,
  ) async => content = await update(content);

  @override
  Future<({int size, DateTime modified})?> fileStat(String path) async =>
      (size: content.length, modified: DateTime.fromMillisecondsSinceEpoch(1));
}

class _IndexedStorage extends _MemoryStorage {
  _IndexedStorage(super.content);

  @override
  Future<bool> fileExists(String path) async => true;

  @override
  Future<String?> readFile(String path) async {
    if (!path.endsWith('.fenidx')) return content;
    return pgn.serializeFenIndex(
      pgn.buildFenIndex([(headers: <String, String>{}, pgnText: content)]),
      gameCount: 1,
      fileSize: content.length,
      modifiedMs: 1,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PgnViewerController controller;
  late PgnGameEntry game;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final analysis = _Analysis();
    controller = PgnViewerController(
      pgnWidgetController: PgnViewerWidgetController(),
      analysisController: analysis,
    );
    game = PgnGameEntry(
      headers: {'Event': 'Practice', 'White': 'A', 'Black': 'B'},
      pgnText: '[Event "Practice"]\n[White "A"]\n[Black "B"]\n\n1. e4 e5 *\n',
    );
    controller.allGames = [game];
    controller.filteredGames = [game];
    addTearDown(() async {
      await controller.flushPendingMetadata();
      controller.dispose();
      analysis.dispose();
      StorageFactory.instanceForTest = null;
    });
  });

  test(
    'adopting an empty collection advances revision before notification',
    () {
      final before = controller.collectionRevision;
      final observed = <int>[];
      controller.addListener(() {
        if (controller.allGames.isEmpty) {
          observed.add(controller.collectionRevision);
        }
      });

      controller.closeFile();

      expect(observed, isNotEmpty);
      expect(observed, everyElement(greaterThan(before)));
    },
  );

  test('rating changes refresh filter headers before listeners run', () {
    final source = controller.allGames;
    final before = controller.collectionRevision;
    final observed = <(int, String?)>[];
    controller.addListener(() {
      observed.add((
        controller.collectionRevision,
        game.headers['StudyRating'],
      ));
    });

    controller.setRating(4);

    expect(controller.allGames, same(source));
    expect(observed.single, (before + 1, '4'));
    controller.setRating(0);
    expect(observed.last, (before + 2, null));
  });

  for (final writeToFile in [true, false]) {
    test(
      'movetext revision reaches listeners with writeToFile=$writeToFile',
      () {
        final source = controller.allGames;
        final before = controller.collectionRevision;
        final observed = <(int, String)>[];
        controller.addListener(() {
          observed.add((controller.collectionRevision, game.pgnText));
        });

        controller.persistMoveCommentsFor(
          game,
          '1. d4 d5 *',
          writeToFile: writeToFile,
        );

        expect(controller.allGames, same(source));
        expect(observed.single.$1, before + 1);
        expect(observed.single.$2, contains('1. d4 d5 *'));
        controller.persistMoveCommentsFor(
          game,
          '1. d4 d5 *',
          writeToFile: writeToFile,
        );
        expect(
          observed,
          hasLength(1),
          reason: 'identical text is not a change',
        );
      },
    );
  }

  test(
    'late edits to an outgoing game do not invalidate the new collection',
    () {
      controller.closeFile();
      final before = controller.collectionRevision;
      controller.persistMoveCommentsFor(game, '1. d4 d5 *', writeToFile: false);
      expect(controller.collectionRevision, before);
    },
  );

  test(
    'metadata rewrite refreshes the raw PGN snapshot before notifying',
    () async {
      final storage = _MemoryStorage(game.pgnText);
      StorageFactory.instanceForTest = storage;
      controller.filePath = '/virtual/games.pgn';
      controller.setRating(3);
      final before = controller.collectionRevision;
      final observed = <(int, String)>[];
      controller.addListener(() {
        observed.add((controller.collectionRevision, game.pgnText));
      });

      await controller.doPersistMetadata();

      expect(observed, isNotEmpty);
      expect(observed.first.$1, greaterThan(before));
      expect(observed.first.$2, contains('[StudyRating "3"]'));
      expect(storage.content, contains('[StudyRating "3"]'));
    },
  );

  test(
    'movetext invalidates the FEN index but rating headers retain it',
    () async {
      StorageFactory.instanceForTest = _IndexedStorage(game.pgnText);
      await controller.loadFile('/virtual/games.pgn', restoreSavedSlice: false);
      final index = controller.fenIndex;
      expect(index, isNotNull);

      controller.setRating(4);
      expect(controller.fenIndex, same(index));
      final before = controller.collectionRevision;
      controller.addListener(() {
        if (controller.collectionRevision > before) {
          expect(controller.fenIndex, isNull);
        }
      });

      controller.persistMoveCommentsFor(
        controller.allGames.single,
        '1. d4 d5 *',
        writeToFile: false,
      );

      expect(controller.collectionRevision, greaterThan(before));
      expect(controller.fenIndex, isNull);
    },
  );

  test('perspective header and text are visible at the new revision', () async {
    controller.perspective = const Perspective(mode: PerspectiveMode.black);
    final before = controller.collectionRevision;
    final observed = <int>[];
    controller.addListener(() {
      observed.add(controller.collectionRevision);
      expect(game.headers['StudyPerspective'], 'black');
      expect(game.pgnText, contains('[StudyPerspective "black"]'));
    });

    await controller.persistPerspective();

    expect(observed.single, before + 1);
    await controller.persistPerspective();
    expect(observed, hasLength(1));
  });

  test(
    'navigation, sorting and slicing leave content revision unchanged',
    () async {
      final before = controller.collectionRevision;

      controller.goToGame(0);
      controller.setSortMode(GameSortMode.dateDesc);
      controller.applySlice([0], const SliceConfig.empty());
      controller.resetFilters();
      await Future<void>.delayed(Duration.zero);

      expect(controller.collectionRevision, before);
    },
  );
}
