import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/app/pgn_viewer_lifetime.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/app/viewer_dependencies.dart';
import 'package:chess_auto_prep/core/app_history.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/documents/models/viewer_collection_load.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_collection_decoder.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_workspace_snapshot.dart';
import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_decoder.dart';
import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_filter.dart';
import 'package:chess_auto_prep/infrastructure/documents/shared_preferences_viewer_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_collection_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_library_repository.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/screens/pgn_viewer_screen.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
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
import '../support/runtime_settings.dart';

class _ControlledDecoder implements PgnCollectionDecoder {
  String? heldContent;
  Completer<void>? gate;
  bool started = false;

  @override
  Future<DecodedPgnCollection> decode(String content) async {
    if (content == heldContent) {
      started = true;
      await gate!.future;
    }
    return const IsolatePgnCollectionDecoder().decode(content);
  }
}

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
  _DelayedRepository(super.storage, {required super.documents});

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
  late _ControlledDecoder decoder;
  late _DelayedRepository repository;
  late _ControlledStorage storage;
  late PgnViewerLifetime lifetime;
  late RuntimeSettings runtimeSettings;
  late AppState app;
  late AppHistory history;
  var lifetimeClosed = false;

  setUp(() {
    lifetimeClosed = false;
    SharedPreferences.setMockInitialValues({
      'game_view.auto_save': false,
      'pgn_viewer.auto_detect_openings': false,
    });
    useScriptedBoardEngine();
    runtimeSettings = testRuntimeSettings();
    addTearDown(runtimeSettings.dispose);
    final engines = testEngines(runtimeSettings);
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
    decoder = _ControlledDecoder();
    repository = _DelayedRepository(
      storage,
      documents: LegacyPgnDocumentStore(storage),
    );
    lifetime = PgnViewerLifetime(
      pool: engines.pool,
      lifecycle: engines.lifecycle,
      positionIndex: createViewerPositionIndex(),
      openings: createViewerOpenings(),
      solitaireRepository: createViewerSolitaire(),
      window: FakeDesktopFullscreenPort(),
      collectionDecoder: decoder,
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
    if (decoder.gate case final gate? when !gate.isCompleted) gate.complete();
    final statGate = storage.statGate;
    if (statGate != null && !statGate.isCompleted) statGate.complete();
    final gate = repository.saveGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    if (!lifetimeClosed) await lifetime.shutdown();
    history.dispose();
    app.dispose();
    StorageFactory.instanceForTest = null;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    directory.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpRuntimeWidget(
      tester,
      runtimeSettings,
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
    await pumpRuntimeWidget(tester, runtimeSettings, const SizedBox.shrink());
    var closed = false;
    final shutdown = lifetime.shutdown().whenComplete(() => closed = true);
    await _until(tester, () => closed, 'Viewer shutdown');
    await shutdown;
    lifetimeClosed = true;
  }

  testWidgets(
    'captured reading collection selects, edits, copies and restores',
    (tester) async {
      try {
        await mount(tester);
        app.handOff(
          const OpenPgnViewer.content(
            content: _games,
            title: 'Browser practice',
            gameIndex: 1,
            ply: 3,
          ),
        );
        await _until(
          tester,
          () =>
              lifetime.document.collection.selectedIndex == 1 &&
              lifetime.reader.mainLineIndex == 3,
          'captured second line at ply three',
        );
        final document = lifetime.document;
        expect(document.filePath, isNull);
        expect(document.collectionTitle, 'Browser practice');
        expect(find.text('Browser practice'), findsWidgets);
        expect(document.collection.games.map((g) => g.headers['Event']), [
          'First game',
          'Requested game',
        ]);
        expect(app.takeHandoff<OpenPgnViewer>(), isNull);
        expect(document.editor.state.needsResolution, isTrue);
        document.persistMoveCommentsFor(
          document.collection.selectedGame!,
          '1. d4 {Reading note} d5 2. c4 e6 *',
        );
        final restore = document.captureNavigationContext();
        final copyPath = '${directory.path}/reading-copy.pgn';
        final result = await tester.runAsync(
          () => document.editor.saveCopy(copyPath),
        );
        expect(result, isA<PgnSaved>());
        expect(File(copyPath).readAsStringSync(), contains('Reading note'));
        expect(File(path).readAsStringSync(), _games);
        expect(repository.writes, 0);
        // A different visit must not replace the captured collection's title,
        // edited games or cursor when breadcrumb restoration returns to it.
        document.editor.discardChanges();
        var changeDone = false;
        final changed = document
            .loadPgnContent(_games, title: 'Other visit')
            .whenComplete(() => changeDone = true);
        await _until(
          tester,
          () =>
              changeDone && document.collectionTitle == 'Other visit',
          'another content visit',
        );
        expect(await changed, isTrue);
        document.editor.discardChanges();
        var restoreDone = false;
        final restored = restore().whenComplete(() => restoreDone = true);
        await _until(
          tester,
          () =>
              restoreDone &&
              document.collectionTitle == 'Browser practice' &&
              lifetime.reader.mainLineIndex == 3,
          'restored title and cursor',
        );
        expect(await restored, isTrue);
        expect(
          document.collection.selectedGame!.pgnText,
          contains('Reading note'),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets('content handoff respects leave cancellation before adoption', (
    tester,
  ) async {
    try {
      await mount(tester);
      app.switchToPgnViewer(path: path);
      await _until(
        tester,
        () =>
            lifetime.document.filePath == path && !lifetime.document.isLoading,
        'backed collection',
      );
      final document = lifetime.document;
      document.persistMoveCommentsFor(
        document.collection.games.first,
        '1. e4 {Keep existing draft} e5 2. Nf3 Nc6 *',
      );
      app.handOff(
        const OpenPgnViewer.content(content: _games, title: 'Unapproved'),
      );
      await _until(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
        'leave approval',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(document.filePath, path);
      expect(document.collectionTitle, 'games');
      expect(
        document.collection.games.first.pgnText,
        contains('Keep existing draft'),
      );
      expect(repository.writes, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await finish(tester);
    }
  });

  testWidgets('late content decoding cannot replace newer file handoff', (
    tester,
  ) async {
    try {
      await mount(tester);
      decoder.heldContent = _games.replaceAll('First game', 'Old request');
      decoder.gate = Completer<void>();
      app.handOff(
        OpenPgnViewer.content(
          content: decoder.heldContent!,
          title: 'Old content',
          gameIndex: 0,
          ply: 1,
        ),
      );
      await _until(tester, () => decoder.started, 'blocked old decoding');
      app.switchToPgnViewer(path: path, gameIndex: 1, ply: 3);
      await _until(
        tester,
        () =>
            lifetime.document.filePath == path &&
            lifetime.reader.mainLineIndex == 3,
        'newer file at requested position',
      );
      decoder.gate!.complete();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      expect(lifetime.document.filePath, path);
      expect(lifetime.document.collectionTitle, 'games');
      expect(lifetime.document.collection.selectedIndex, 1);
      expect(lifetime.reader.mainLineIndex, 3);
      expect(tester.takeException(), isNull);
    } finally {
      if (decoder.gate case final gate? when !gate.isCompleted) gate.complete();
      await finish(tester);
    }
  });

  testWidgets(
    'an edit after the approval click prevents discarding the newer draft',
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
          'loaded first game',
        );
        final document = lifetime.document;
        document.editor.setAutoSave(false);
        final game = document.collection.games.first;
        document.persistMoveCommentsFor(
          game,
          '1. e4 {Earlier draft} e5 2. Nf3 Nc6 *',
        );
        await tester.pump();
        await tester.tap(
          find.byTooltip('Open games — recent files, browse, or paste'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Close file — back to the start screen'));
        await tester.pumpAndSettle();
        final discard = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Close without saving'),
        );
        // Complete the click synchronously, then edit before the awaiting screen
        // continuation runs. Its approval names only the previous revision.
        discard.onPressed!();
        document.persistMoveCommentsFor(
          game,
          '1. e4 {Newer retained draft} e5 2. Nf3 Nc6 *',
        );
        await tester.pumpAndSettle();
        expect(document.filePath, path);
        expect(document.editor.hasUnsavedChanges, isTrue);
        expect(game.pgnText, contains('Newer retained draft'));
        expect(repository.writes, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'a comment typed during close autosave still requires resolution',
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
          'loaded first game',
        );
        lifetime.reader.goForward();
        await tester.pump();
        await tester.tap(find.text('Actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edit'));
        await tester.pumpAndSettle();
        expect(find.byType(PgnAnnotationPanel), findsOneWidget);
        await tester.tap(
          find.byTooltip('Open games — recent files, browse, or paste'),
        );
        await tester.pumpAndSettle();
        final document = lifetime.document;
        final game = document.collection.games.first;
        repository.saveGate = Completer<void>();
        document.editor.setAutoSave(true);
        document.persistMoveCommentsFor(
          game,
          '1. e4 {Earlier autosave} e5 2. Nf3 Nc6 *',
        );
        await tester.tap(find.text('Close file — back to the start screen'));
        await _until(
          tester,
          () => repository.writes == 1,
          'blocked close autosave',
        );
        await tester.enterText(
          find
              .descendant(
                of: find.byType(PgnAnnotationPanel),
                matching: find.byType(TextField),
              )
              .first,
          'Typed while autosave waited',
        );
        expect(game.pgnText, isNot(contains('Typed while autosave waited')));
        document.editor.setAutoSave(false);
        repository.saveGate!.complete();
        await _until(
          tester,
          () => !document.editor.state.busy,
          'completed earlier autosave',
        );
        expect(document.filePath, path);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(game.pgnText, contains('Typed while autosave waited'));
        expect(document.editor.hasUnsavedChanges, isTrue);
        await tester.tap(find.text('Cancel'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(document.filePath, path);
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

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
