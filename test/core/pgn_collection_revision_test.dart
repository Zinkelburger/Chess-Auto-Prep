import 'package:chess_auto_prep/utils/atomic_file.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/models/pgn_game_entry.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/app/engine_runtime.dart';
import '../support/runtime_settings.dart';
import 'package:chess_auto_prep/app/viewer_dependencies.dart';
import 'package:chess_auto_prep/features/documents/models/viewer_collection_load.dart';
import '../support/fake_desktop_fullscreen_port.dart';
import 'package:chess_auto_prep/features/documents/models/viewer_perspective.dart';
import 'dart:async';

import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_filter.dart';

import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_library_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_decoder.dart';

import 'package:chess_auto_prep/infrastructure/documents/shared_preferences_viewer_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_collection_repository.dart';

import 'package:chess_auto_prep/features/documents/controllers/viewer_document_controller.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/services/game_analysis_controller.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_position_replay.dart' as pgn;
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Analysis extends GameAnalysisController {
  _Analysis() : super(pool: engines.pool, lifecycle: engines.lifecycle);
  @override
  Future<bool> tryLoadFromPgn(String pgnText) async => false;

  @override
  void cancel() {}
}

class _MemoryStorage extends IOStorageService {
  _MemoryStorage(this.content);

  String content;

  @override
  Future<void> writeFile(
    String path,
    String next, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (createOnly || (expectedContent != null && expectedContent != content)) {
      throw AtomicWriteConflict(path);
    }
    content = next;
  }

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

RuntimeSettings? _engineFixtureSettings;
EngineRuntime get engines =>
    testEngines(_engineFixtureSettings ??= testRuntimeSettings());
void main() {
  setUp(() {
    _engineFixtureSettings = null;
    addTearDown(() => _engineFixtureSettings?.dispose());
  });
  TestWidgetsFlutterBinding.ensureInitialized();

  late ViewerDocumentController controller;
  late PgnGameEntry game;
  late _IndexedStorage storage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storage = _IndexedStorage(
      '[Event "Practice"]\n[White "A"]\n[Black "B"]\n\n1. e4 e5 *\n',
    );
    StorageFactory.instanceForTest = storage;
    final analysis = _Analysis();
    controller = ViewerDocumentController(
      positionIndex: createViewerPositionIndex(),
      openings: createViewerOpenings(),
      solitaireRepository: createViewerSolitaire(),
      window: FakeDesktopFullscreenPort(),
      collectionDecoder: const IsolatePgnCollectionDecoder(),
      collectionFilter: const IsolatePgnCollectionFilter(),
      library: StoragePgnLibraryRepository(
        StorageFactory.instance,
        directory: () async => '/collections',
      ),
      preferences: SharedPreferencesViewerRepository(
        SharedPreferences.getInstance,
      ),
      collectionRepository: StoragePgnCollectionRepository(
        StorageFactory.instance,
        documents: LegacyPgnDocumentStore(StorageFactory.instance),
      ),
      pgnWidgetController: PgnViewerWidgetController(),
      analysisController: analysis,
    );
    game = PgnGameEntry(
      headers: {'Event': 'Practice', 'White': 'A', 'Black': 'B'},
      pgnText: '[Event "Practice"]\n[White "A"]\n[Black "B"]\n\n1. e4 e5 *\n',
    );
    controller.adoptDecodedCollection(DecodedPgnCollection([game], ''));
    addTearDown(() async {
      await controller.editor.flushPendingMetadata();
      controller.dispose();
      analysis.dispose();
      StorageFactory.instanceForTest = null;
    });
  });

  test(
    'adopting an empty collection advances revision before notification',
    () {
      final before = controller.collection.contentRevision;
      final observed = <int>[];
      controller.changes.addListener(() {
        if (controller.collection.games.isEmpty) {
          observed.add(controller.collection.contentRevision);
        }
      });

      controller.closeFile();

      expect(observed, isNotEmpty);
      expect(observed, everyElement(greaterThan(before)));
    },
  );

  test('save-state notifications preserve unrelated load failures', () {
    controller.errorMessage = 'The requested file could not be opened';
    controller.editor.setAutoSave(false);
    expect(controller.errorMessage, 'The requested file could not be opened');
    controller.editor.setRating(3);
    expect(controller.errorMessage, 'The requested file could not be opened');
  });

  test('rating changes refresh filter headers before listeners run', () {
    final source = controller.collection.games;
    final before = controller.collection.contentRevision;
    final observed = <(int, String?)>[];
    controller.changes.addListener(() {
      observed.add((
        controller.collection.contentRevision,
        game.headers['StudyRating'],
      ));
    });

    controller.editor.setRating(4);

    expect(controller.collection.games, same(source));
    expect(observed.single, (before + 1, '4'));
    controller.editor.setRating(0);
    expect(observed.last, (before + 2, null));
  });

  for (final writeToFile in [true, false]) {
    test(
      'movetext revision reaches listeners with writeToFile=$writeToFile',
      () {
        final source = controller.collection.games;
        final before = controller.collection.contentRevision;
        final observed = <(int, String)>[];
        controller.changes.addListener(() {
          observed.add((controller.collection.contentRevision, game.pgnText));
        });

        controller.persistMoveCommentsFor(
          game,
          '1. d4 d5 *',
          writeToFile: writeToFile,
        );

        expect(controller.collection.games, same(source));
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

  for (final writeToFile in [false, true]) {
    test(
      'late outgoing annotations cannot edit or dirty a replacement (write=$writeToFile)',
      () {
        final original = game.pgnText;
        controller.closeFile();
        controller.adoptDecodedCollection(
          DecodedPgnCollection([
            PgnGameEntry(
              headers: {'Event': 'Replacement'},
              pgnText: '[Event "Replacement"]\n\n1. c4 *',
            ),
          ], ''),
        );
        final before = controller.collection.contentRevision;
        controller.persistMoveCommentsFor(
          game,
          '1. d4 d5 *',
          writeToFile: writeToFile,
        );
        expect(controller.collection.contentRevision, before);
        expect(controller.editor.hasUnsavedChanges, isFalse);
        expect(game.pgnText, original);
      },
    );
  }

  test(
    'metadata rewrite refreshes the raw PGN snapshot before notifying',
    () async {
      controller.filePath = '/virtual/games.pgn';
      controller.editor.setRating(3);
      final before = controller.collection.contentRevision;
      final observed = <(int, String)>[];
      controller.changes.addListener(() {
        observed.add((controller.collection.contentRevision, game.pgnText));
      });

      await controller.editor.doPersistMetadata();

      expect(observed, isNotEmpty);
      expect(observed.first.$1, greaterThan(before));
      expect(observed.first.$2, contains('[StudyRating "3"]'));
      expect(storage.content, contains('[StudyRating "3"]'));
    },
  );

  test(
    'movetext invalidates the FEN index but rating headers retain it',
    () async {
      await controller.loadFile('/virtual/games.pgn', restoreSavedSlice: false);
      // The persisted index is restored by the deferred collection
      // preparation, which runs after the game is already on screen.
      while (controller.isPreparingCollection) {
        await Future<void>.delayed(Duration.zero);
      }
      final index = controller.positionIndexController.value;
      expect(index, isNotNull);

      controller.editor.setRating(4);
      expect(controller.positionIndexController.value, same(index));
      final before = controller.collection.contentRevision;
      controller.changes.addListener(() {
        if (controller.collection.contentRevision > before) {
          expect(controller.positionIndexController.value, isNull);
        }
      });

      controller.persistMoveCommentsFor(
        controller.collection.games.single,
        '1. d4 d5 *',
        writeToFile: false,
      );

      expect(controller.collection.contentRevision, greaterThan(before));
      expect(controller.positionIndexController.value, isNull);
    },
  );

  test('perspective header and text are visible at the new revision', () async {
    controller.presentation.restoreBoard(
      perspective: const Perspective(mode: PerspectiveMode.black),
    );
    final before = controller.collection.contentRevision;
    final observed = <int>[];
    controller.changes.addListener(() {
      observed.add(controller.collection.contentRevision);
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
      final before = controller.collection.contentRevision;

      controller.reading.goToGame(0);
      controller.setSortMode(GameSortMode.dateDesc);
      controller.applySlice([0], const SliceConfig.empty());
      controller.resetFilters();
      await Future<void>.delayed(Duration.zero);

      expect(controller.collection.contentRevision, before);
    },
  );
}
