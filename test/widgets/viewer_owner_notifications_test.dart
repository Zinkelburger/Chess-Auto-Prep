import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/app/pgn_viewer_lifetime.dart';
import 'package:chess_auto_prep/app/viewer_dependencies.dart';
import 'package:chess_auto_prep/core/app_history.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_workspace_snapshot.dart';
import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_decoder.dart';
import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_filter.dart';
import 'package:chess_auto_prep/infrastructure/documents/shared_preferences_viewer_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_collection_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_library_repository.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/screens/pgn_viewer_screen.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart'
    show dedupKeyForHeaders;
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/board_engine_fixture.dart';
import '../support/fake_desktop_fullscreen_port.dart';
import '../support/memory_workspace_recovery_store.dart';

class _Preferences extends SharedPreferencesViewerRepository {
  _Preferences() : super(SharedPreferences.getInstance);

  bool failRecentFiles = false;
  int failedRecentReads = 0;

  @override
  Future<List<String>> loadRecentFiles() async {
    if (failRecentFiles) {
      failedRecentReads++;
      throw StateError('Recent-file preferences unavailable');
    }
    return super.loadRecentFiles();
  }

  @override
  Future<void> saveRecentFiles(List<String> paths) async {
    if (failRecentFiles) {
      throw StateError('Recent-file preferences unavailable');
    }
    await super.saveRecentFiles(paths);
  }
}

class _DelayedRepository extends StoragePgnCollectionRepository {
  _DelayedRepository(super.storage);

  Completer<void>? saveGate;
  int writes = 0;

  Future<void> _waitForSave() async {
    writes++;
    await saveGate?.future;
  }

  @override
  Future<PgnWriteResult> save(PgnSnapshot baseline, String content) async {
    await _waitForSave();
    return super.save(baseline, content);
  }

  @override
  Future<PgnWriteResult> patch(
    String path,
    Map<String, String> replacements,
  ) async {
    await _waitForSave();
    return super.patch(path, replacements);
  }
}

class _ControlledStorage extends IOStorageService {
  _ControlledStorage({super.documentsRoot, super.supportRoot});

  String? holdNextStatFor;
  Completer<void>? statGate;
  Completer<void>? statStarted;
  Completer<void>? statDelivered;

  @override
  Future<({int size, DateTime modified})?> fileStat(String path) async {
    if (path != holdNextStatFor) return super.fileStat(path);
    holdNextStatFor = null;
    final gate = statGate!;
    final result = await super.fileStat(path);
    statStarted!.complete();
    await gate.future;
    statDelivered!.complete();
    return result;
  }
}

// The production reader decodes files and PGN widgets in isolates. Alternate
// real event-loop turns with frames until the requested observable state lands.
Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String description,
) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 30));
    if (ready()) return;
  }
  fail('Viewer did not reach $description');
}

const _games = '''[Event "First game"]
[White "A"]
[Black "B"]

1. e4 e5 2. Nf3 Nc6 *

[Event "Requested game"]
[White "C"]
[Black "D"]

1. d4 d5 2. c4 e6 *
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String path;
  late _Preferences preferences;
  late _DelayedRepository repository;
  late _ControlledStorage storage;
  late PgnViewerLifetime lifetime;
  late AppState app;
  late AppHistory history;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'game_view.auto_save': false,
      'pgn_viewer.auto_detect_openings': false,
    });
    EngineLifecycle.instance.resetForTest();
    EngineLifecycle.testMode = true;
    useScriptedBoardEngine();
    directory = Directory.systemTemp.createTempSync('viewer-owner-events-');
    path = '${directory.path}/games.pgn';
    File(path).writeAsStringSync(_games);
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => directory.path);
    storage = _ControlledStorage(
      documentsRoot: directory,
      supportRoot: directory,
    );
    StorageFactory.instanceForTest = storage;
    preferences = _Preferences();
    repository = _DelayedRepository(storage);
    lifetime = PgnViewerLifetime(
      positionIndex: createViewerPositionIndex(),
      openings: createViewerOpenings(),
      solitaireRepository: createViewerSolitaire(),
      window: FakeDesktopFullscreenPort(),
      collectionDecoder: const IsolatePgnCollectionDecoder(),
      collectionFilter: const IsolatePgnCollectionFilter(),
      library: StoragePgnLibraryRepository(
        storage,
        directory: () async => directory.path,
      ),
      preferences: preferences,
      repository: repository,
      store: MemoryWorkspaceRecoveryStore<PgnWorkspaceSnapshot>(),
    );
    app = AppState()..pushMode(AppMode.pgnViewer, historyLabel: 'Game viewer');
    history = AppHistory(app);
  });

  tearDown(() async {
    final statGate = storage.statGate;
    if (statGate != null && !statGate.isCompleted) statGate.complete();
    final gate = repository.saveGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    await lifetime.shutdown();
    history.dispose();
    app.dispose();
    StorageFactory.instanceForTest = null;
    EngineLifecycle.instance.resetForTest();
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    directory.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: app),
          ChangeNotifierProvider.value(value: history),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PgnViewerCloseHost(
            lifetime: lifetime,
            child: PgnViewerScreen(lifetime: lifetime),
          ),
        ),
      ),
    );
  }

  Future<void> finish(WidgetTester tester) async {
    final statGate = storage.statGate;
    if (statGate != null && !statGate.isCompleted) statGate.complete();
    final gate = repository.saveGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(lifetime.shutdown);
  }

  testWidgets('leave dialog follows editor busy and saved notifications', (
    tester,
  ) async {
    try {
      await mount(tester);
      app.switchToPgnViewer(path: path);
      await _until(
        tester,
        () =>
            lifetime.document.filePath == path &&
            !lifetime.document.isLoading &&
            lifetime.reader.mainLineLength == 4,
        'loaded first game',
      );
      lifetime.document.editor.setAutoSave(false);
      lifetime.document.persistMoveCommentsFor(
        lifetime.document.collection.games.first,
        '1. e4 {Keep this edit} e5 2. Nf3 Nc6 *',
      );
      await tester.pump();
      expect(lifetime.document.editor.hasUnsavedChanges, isTrue);
      await tester.tap(
        find.byTooltip('Open games — recent files, browse, or paste'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close file — back to the start screen'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      final discard = find.descendant(
        of: dialog,
        matching: find.widgetWithText(TextButton, 'Close without saving'),
      );
      expect(tester.widget<TextButton>(discard).onPressed, isNotNull);
      repository.saveGate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('document-save')));
      await tester.pump();
      expect(lifetime.document.editor.state.busy, isTrue);
      expect(tester.widget<TextButton>(discard).onPressed, isNull);
      await _until(
        tester,
        () => repository.writes == 1,
        'pending document write',
      );
      repository.saveGate!.complete();
      await _until(
        tester,
        () =>
            !lifetime.document.editor.state.busy &&
            !lifetime.document.editor.hasUnsavedChanges,
        'acknowledged save',
      );
      expect(discard, findsNothing);
      final continueButton = find.descendant(
        of: dialog,
        matching: find.widgetWithText(FilledButton, 'Close'),
      );
      expect(continueButton, findsOneWidget);
      expect(
        await tester.runAsync(() => File(path).readAsString()),
        contains('Keep this edit'),
      );
      await tester.tap(continueButton);
      await tester.pumpAndSettle();
      expect(lifetime.document.filePath, isNull);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await finish(tester);
    }
  });

  testWidgets(
    'older handoff stat cannot replace a newer game and reading position',
    (tester) async {
      try {
        await mount(tester);
        app.switchToPgnViewer(path: path);
        await _until(
          tester,
          () =>
              lifetime.document.filePath == path &&
              !lifetime.document.isLoading &&
              lifetime.reader.mainLineLength == 4,
          'loaded collection before overlapping handoffs',
        );
        expect(lifetime.document.loadedFileModified, isNotNull);
        final first = lifetime.document.collection.games.first;
        final second = lifetime.document.collection.games.last;
        final firstId = dedupKeyForHeaders(first.headers, pgn: first.pgnText);
        final secondId = dedupKeyForHeaders(
          second.headers,
          pgn: second.pgnText,
        );
        expect(firstId, isNot(secondId));
        storage.holdNextStatFor = path;
        storage.statGate = Completer<void>();
        storage.statStarted = Completer<void>();
        storage.statDelivered = Completer<void>();

        app.switchToPgnViewer(path: path, gameId: firstId, ply: 1);
        await _until(
          tester,
          () => storage.statStarted!.isCompleted,
          'older handoff waiting for its file stat',
        );
        app.switchToPgnViewer(path: path, gameId: secondId, ply: 3);
        await _until(
          tester,
          () =>
              identical(lifetime.document.collection.selectedGame, second) &&
              lifetime.reader.mainLineIndex == 3 &&
              lifetime.reader.mainLineMoves.first == 'd4',
          'newer handoff on the second game at ply three',
        );

        storage.statGate!.complete();
        await _until(
          tester,
          () => storage.statDelivered!.isCompleted,
          'obsolete stat response delivered',
        );
        // _until drains the real stat continuation and pumps its frame. The
        // board may keep an engine progress animation alive independently.
        await tester.pump();
        expect(lifetime.document.filePath, path);
        expect(lifetime.document.collection.selectedGame, same(second));
        expect(lifetime.reader.mainLineIndex, 3);
        expect(lifetime.reader.mainLineMoves.take(3), ['d4', 'd5', 'c4']);
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'recent-file preference failure does not block game and ply handoff',
    (tester) async {
      try {
        preferences.failRecentFiles = true;
        await mount(tester);
        await _until(
          tester,
          () =>
              preferences.failedRecentReads == 1 &&
              lifetime.document.libraryState.errorMessage != null,
          'visible independent recent-file failure',
        );
        app.switchToPgnViewer(path: path, gameIndex: 1, ply: 3);
        await _until(
          tester,
          () =>
              lifetime.document.filePath == path &&
              lifetime.document.collection.selectedIndex == 1 &&
              lifetime.reader.mainLineIndex == 3,
          'requested second game at ply three',
        );
        expect(lifetime.document.errorMessage, isNull);
        expect(lifetime.document.libraryState.errorMessage, isNotNull);
        expect(
          lifetime.document.collection.visibleGames[1].headers['Event'],
          'Requested game',
        );
        expect(lifetime.reader.mainLineMoves.take(3), ['d4', 'd5', 'c4']);
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );
}
