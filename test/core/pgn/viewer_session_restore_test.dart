import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/app/engine_runtime.dart';
import '../../support/runtime_settings.dart';
import 'package:chess_auto_prep/app/viewer_dependencies.dart';
import '../../support/fake_desktop_fullscreen_port.dart';
import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_filter.dart';

import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_library_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_decoder.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_collection.dart';

import 'package:chess_auto_prep/features/documents/models/viewer_session.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_preferences_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/shared_preferences_viewer_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_collection_repository.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess_auto_prep/features/documents/controllers/viewer_document_controller.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_viewer_handle.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/features/games/models/game_view_preferences.dart';
import 'package:chess_auto_prep/services/game_analysis_controller.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_text.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';

class _Handle implements PgnViewerHandle {
  @override
  int mainLineIndex = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Analysis extends GameAnalysisController {
  _Analysis() : super(pool: engines.pool, lifecycle: engines.lifecycle);
  @override
  Future<bool> tryLoadFromPgn(String pgnText) async => false;
  @override
  void cancel() {}
}

Future<void> _waitForPreparation(ViewerDocumentController controller) async {
  if (!controller.isPreparingCollection) return;
  final done = Completer<void>();
  void changed() {
    if (!controller.isPreparingCollection && !done.isCompleted) done.complete();
  }

  controller.changes.addListener(changed);
  try {
    await done.future.timeout(const Duration(seconds: 15));
  } finally {
    controller.changes.removeListener(changed);
  }
}

class _FailingSessionPreferences extends SharedPreferencesViewerRepository {
  _FailingSessionPreferences() : super(SharedPreferences.getInstance);
  bool fail = false;
  @override
  Future<void> saveSession(String path, ViewerSession session) async {
    if (fail) throw StateError('preference write rejected');
    await super.saveSession(path, session);
  }
}

class _FailedOpeningPreferences extends SharedPreferencesViewerRepository {
  _FailedOpeningPreferences() : super(SharedPreferences.getInstance);
  @override
  Future<bool> autoDetectOpenings() async => throw StateError('unavailable');
}

class _DelayedRecentPreferences extends SharedPreferencesViewerRepository {
  _DelayedRecentPreferences() : super(SharedPreferences.getInstance);
  final pending = Completer<List<String>>();
  @override
  Future<List<String>> loadRecentFiles() => pending.future;
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
  late Directory dir;
  late String path;
  final controllers = <ViewerDocumentController>[];
  ViewerDocumentController make([
    _Handle? handle,
    ViewerPreferencesRepository? preferences,
  ]) {
    final controller = ViewerDocumentController(
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
      preferences:
          preferences ??
          SharedPreferencesViewerRepository(SharedPreferences.getInstance),
      collectionRepository: StoragePgnCollectionRepository(
        StorageFactory.instance,
        documents: LegacyPgnDocumentStore(StorageFactory.instance),
      ),
      pgnWidgetController: handle ?? _Handle(),
      analysisController: _Analysis(),
    );
    controllers.add(controller);
    return controller;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('viewer-session-test-');
    StorageFactory.instanceForTest = IOStorageService(documentsRoot: dir);
    path = p.join(dir.path, 'fischer.pgn');
    await File(path).writeAsString(
      '; Collection banner\n\n${List.generate(40, (i) => '[Event "Game $i"]\n[White "Fischer, Robert"]\n[Black "Opponent $i"]\n[Date "${1959 + i}.??.??"]\n\n1. e4 c5 2. Nf3 d6 3. d4 cxd4 *').join('\n\n')}\n',
    );
  });

  tearDown(() async {
    for (final controller in controllers) {
      await _waitForPreparation(controller);
      await controller.editor.flushPendingMetadata();
      await controller.reading.saveSession();
      controller.dispose();
    }
    controllers.clear();
    StorageFactory.instanceForTest = null;
    await dir.delete(recursive: true);
  });

  test(
    'reading checkpoint failure stays visible until a successful retry',
    () async {
      final preferences = _FailingSessionPreferences();
      final handle = _Handle();
      final controller = make(handle, preferences);
      await controller.loadFile(path);
      final unchanged = await File(path).readAsString();
      preferences.fail = true;
      handle.mainLineIndex = 4;
      controller.reading.rememberReadingPosition();
      await controller.reading.saveSession();
      expect(
        controller.reading.errorMessage,
        contains('Could not save the reading position'),
      );
      preferences.fail = false;
      await controller.reading.saveSession();
      expect(controller.reading.errorMessage, isNull);
      expect((await preferences.loadSession(path))!.ply, 4);
      expect(await File(path).readAsString(), unchanged);
      controller.reading.errorMessage = 'A newer analysis failure';
      await controller.reading.saveSession();
      expect(controller.reading.errorMessage, 'A newer analysis failure');
    },
  );

  test(
    'pasted games stay readable when opening preferences cannot be read',
    () async {
      final controller = make(null, _FailedOpeningPreferences());
      await controller.loadPgnContent('[Event "Pasted"]\n\n1. e4 e5 *');
      expect(controller.collection.games.single.pgnText, contains('1. e4 e5'));
      expect(controller.isLoading, isFalse);
      expect(controller.autoDetectOpenings, isFalse);
      expect(
        controller.errorMessage,
        contains('opening-detection preferences'),
      );
    },
  );

  test(
    'restoring a saved filter does not borrow the departed reader cursor',
    () async {
      final preferences = SharedPreferencesViewerRepository(
        SharedPreferences.getInstance,
      );
      await preferences.saveSlice(
        path,
        const SliceConfig(
          headerFilters: [
            HeaderFilterConfig(
              field: 'Event',
              mode: MatchMode.exact,
              value: 'Game 0',
            ),
          ],
        ),
      );
      final controller = make(_Handle()..mainLineIndex = 5, preferences);
      await controller.loadFile(path);
      expect(controller.collection.visibleGames, hasLength(1));
      expect(
        controller.reading.resumePlyFor(
          controller.collection.visibleGames.single,
        ),
        0,
      );
    },
  );

  test('a delayed recent-file read cannot erase a newly opened file', () async {
    final preferences = _DelayedRecentPreferences();
    final controller = make(null, preferences);
    final loading = controller.libraryState.loadRecentFiles();
    await controller.libraryState.addToRecentFiles(path);
    preferences.pending.complete([]);
    await loading;
    expect(controller.libraryState.recentFiles, [path]);
  });

  test(
    'OR and multiple positions survive reopen, chip removal and presets',
    () async {
      final first = make();
      await first.loadFile(path);
      const config = SliceConfig(
        matchAny: true,
        positionInput: '1. c4',
        additionalPositions: ['1. e4', '1. d4'],
        headerFilters: [
          HeaderFilterConfig(
            field: 'Event',
            mode: MatchMode.exact,
            value: 'Game 0',
          ),
        ],
      );
      await first.recomputeAndApplyConfig(config);
      await first.preferences.saveSlice(first.filePath!, config);
      final reopened = make();
      await reopened.loadFile(path);
      expect(reopened.collection.visibleGames, hasLength(40));
      expect(
        reopened.filters.selection.config.toJsonString(),
        config.toJsonString(),
      );
      await reopened.removeSliceChip(1);
      expect(reopened.collection.visibleGames, hasLength(1));
      expect(reopened.filters.selection.config.additionalPositions, ['1. d4']);
      expect(reopened.filters.selection.config.matchAny, isTrue);
      await reopened.applySlicePreset(
        const HeaderFilterConfig(
          field: 'Black',
          mode: MatchMode.exact,
          value: 'Opponent 1',
        ),
      );
      expect(reopened.collection.visibleGames, hasLength(2));
      expect(reopened.filters.selection.config.additionalPositions, ['1. d4']);
      expect(reopened.filters.selection.config.matchAny, isTrue);
    },
  );

  test(
    'opening detection never writes staged edits in manual-save mode',
    () async {
      final c = make()..editor.setAutoSave(false);
      final original = await File(path).readAsString();
      await c.loadFile(path);
      await _waitForPreparation(c);
      expect(await File(path).readAsString(), original);
      expect(c.editor.hasUnsavedChanges, isTrue);
      expect(c.collection.games.first.headers['ECO'], isNotEmpty);
      expect(await c.editor.saveChanges(), isTrue);
      expect(await File(path).readAsString(), contains('[ECO "'));
    },
  );

  test(
    'restart restores file, date slice, game 37 and move; reordered files keep identity',
    () async {
      final handle = _Handle();
      final first = make(handle);
      await first.loadFile(path);
      expect(first.errorMessage, isNull);
      const config = SliceConfig(
        headerFilters: [
          HeaderFilterConfig(
            field: 'Date',
            mode: MatchMode.after,
            value: '1960',
          ),
        ],
      );
      await first.recomputeAndApplyConfig(config);
      await first.preferences.saveSlice(first.filePath!, config);
      first.reading.goToGame(36);
      handle.mainLineIndex = 4;
      first.reading.rememberReadingPosition();
      await first.reading.saveSession();
      final selected = first
          .collection
          .visibleGames[first.collection.selectedIndex]
          .headers['Event'];

      final reopened = make();
      await reopened.restoreLastSession();
      expect(reopened.filePath, path);
      expect(reopened.collection.selectedIndex, 36);
      expect(reopened.collection.visibleGames, hasLength(39));
      expect(
        reopened.filters.selection.config.toJsonString(),
        config.toJsonString(),
      );
      expect(
        reopened.reading.resumePlyFor(reopened.collection.visibleGames[36]),
        4,
      );

      reopened.setSortMode(GameSortMode.dateDesc);
      final index = reopened.collection.visibleGames.indexWhere(
        (g) => g.headers['Event'] == selected,
      );
      reopened.reading.goToGame(index);
      await reopened.reading.saveSession();
      final third = make();
      await third.loadFile(path);
      expect(third.collection.sortMode, GameSortMode.dateDesc);
      expect(
        third
            .collection
            .visibleGames[third.collection.selectedIndex]
            .headers['Event'],
        selected,
      );

      // Insertions/reordering must not restore an unrelated game at the old index.
      final games = parseMultiGamePgn(await File(path).readAsString());
      await File(
        path,
      ).writeAsString(games.reversed.map((g) => g.pgnText).join('\n\n'));
      final fourth = make();
      await fourth.loadFile(path);
      expect(
        fourth
            .collection
            .visibleGames[fourth.collection.selectedIndex]
            .headers['Event'],
        selected,
      );
    },
  );

  test(
    'ECO tags are saved for all games; ECO slice restores; off prevents writes',
    () async {
      final first = make();
      await first.loadFile(path);
      await _waitForPreparation(first);
      final text = await File(path).readAsString();
      expect(text, startsWith('; Collection banner'));
      expect(
        first.collection.games.every(
          (g) => g.headers['ECO'] != null && g.headers['Opening'] != null,
        ),
        isTrue,
      );
      expect(
        parseMultiGamePgn(text).every((g) => g.headers['ECO'] != null),
        isTrue,
      );
      final eco = first.collection.games.first.headers['ECO']!;
      final config = SliceConfig(
        headerFilters: [
          HeaderFilterConfig(field: 'ECO', mode: MatchMode.exact, value: eco),
        ],
      );
      await first.recomputeAndApplyConfig(config);
      await first.preferences.saveSlice(first.filePath!, config);
      final second = make();
      await second.loadFile(path);
      expect(
        second.filters.selection.config.toJsonString(),
        config.toJsonString(),
      );
      expect(second.collection.visibleGames, hasLength(40));

      await const GameViewPreferences(autoDetectOpenings: false).save();
      final other = p.join(dir.path, 'no-tags.pgn');
      const raw = '[White "A"]\n[Black "B"]\n\n1. e4 e5 *';
      await File(other).writeAsString(raw);
      final off = make();
      await off.loadFile(other);
      await _waitForPreparation(off);
      expect(off.autoDetectOpenings, isFalse);
      expect(off.collection.games.single.headers['ECO'], isNull);
      expect(await File(other).readAsString(), raw);
    },
  );

  test(
    'explicit handoff skips saved place; closing clears auto-reopen only',
    () async {
      final first = make();
      await first.loadFile(path);
      first.reading.goToGame(10);
      await first.reading.saveSession();
      final handoff = make();
      await handoff.loadFile(path, restoreSavedSlice: false);
      expect(handoff.collection.selectedIndex, 0);
      handoff.closeFile();
      await SharedPreferencesViewerRepository(
        SharedPreferences.getInstance,
      ).loadSession(path); // allow queued preferences IO
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final fresh = make();
      await fresh.restoreLastSession();
      expect(fresh.filePath, isNull);
      expect(
        await SharedPreferencesViewerRepository(
          SharedPreferences.getInstance,
        ).loadSession(path),
        isNotNull,
      );
    },
  );
}
