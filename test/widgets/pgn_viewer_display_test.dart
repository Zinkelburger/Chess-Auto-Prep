import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/features/games/services/my_repertoire_settings.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/app/engine_runtime.dart';
import '../support/runtime_settings.dart';
import 'package:chess_auto_prep/app/viewer_dependencies.dart';
import '../support/fake_desktop_fullscreen_port.dart';
import 'dart:io';

import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_filter.dart';

import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_library_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_decoder.dart';

import 'package:chess_auto_prep/infrastructure/documents/shared_preferences_viewer_repository.dart';
import 'package:chess_auto_prep/app/pgn_viewer_lifetime.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_workspace_snapshot.dart';
import '../support/memory_workspace_recovery_store.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_collection_repository.dart';

import 'package:chess_auto_prep/features/documents/controllers/document_close_coordinator.dart';
import 'package:chess_auto_prep/features/documents/widgets/document_close_scope.dart';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/core/app_history.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/screens/pgn_viewer_screen.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_opening_label.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:chess_auto_prep/widgets/slice/header_filters.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_tree_games_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/board_engine_fixture.dart';

// The reader starts real file/isolate work from frame callbacks. One fixed
// runAsync delay before pumpAndSettle cannot finish work that the next frame
// starts. Alternate real event-loop turns with frames until loading settles.
Future<void> _settleReader(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 350));
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (!tester.binding.hasScheduledFrame) return;
  }
  fail('The reader did not settle after file and filter work.');
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
  late PgnViewerLifetime lifetime;
  setUp(() {
    SharedPreferences.setMockInitialValues({});

    useScriptedBoardEngine();
    const windowChannel = MethodChannel('window_manager');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, null);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return {
              'text':
                  '[White "A"]\n[Black "B"]\n[ECO "E94"]\n[Opening "King’s Indian Defense: Orthodox Variation"]\n\n1. d4 Nf6 *',
            };
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    final directory = Directory.systemTemp.createTempSync('engine-shortcut-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => directory.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      directory.deleteSync(recursive: true);
    });
    lifetime = PgnViewerLifetime(
      pool: engines.pool,
      lifecycle: engines.lifecycle,
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
      repository: StoragePgnCollectionRepository(
        StorageFactory.instance,
        documents: LegacyPgnDocumentStore(StorageFactory.instance),
      ),
      store: MemoryWorkspaceRecoveryStore<PgnWorkspaceSnapshot>(),
    );
    addTearDown(lifetime.shutdown);
  });

  testWidgets('Book keyboard navigation leaves the hidden game at its cursor', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final folder = Directory.systemTemp.createTempSync('viewer-book-routing-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final app = AppState()..setMode(AppMode.pgnViewer);
    addTearDown(app.dispose);
    await pumpRuntimeWidget(
      tester,
      _engineFixtureSettings ??= testRuntimeSettings(),
      ChangeNotifierProvider.value(
        value: app,
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
    await _settleReader(tester);
    File('${folder.path}/Main.pgn').writeAsStringSync(
      '[Event "Prepared line"]\n[Result "*"]\n\n1. d4 d5 2. c4 e6 *',
    );
    await MyRepertoireSettings.instance.setPaths(
      white: true,
      paths: [folder.path],
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settleReader(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _settleReader(tester);
    final gamePly = lifetime.reader.mainLineIndex;
    expect(gamePly, 1);
    await tester.tap(find.text('Actions'));
    await _settleReader(tester);
    await tester.tap(find.text('Compare against my books'));
    await _settleReader(tester);
    final bookWidget = find.byWidgetPredicate(
      (widget) => widget is PgnViewerWidget && widget.bookFormatting,
    );
    for (var i = 0; i < 40 && bookWidget.evaluate().isEmpty; i++) {
      await _settleReader(tester);
    }
    expect(bookWidget, findsOneWidget);
    final book = tester.widget<PgnViewerWidget>(bookWidget).controller!;
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await _settleReader(tester);
    expect(book.mainLineIndex, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _settleReader(tester);
    expect(book.mainLineIndex, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await _settleReader(tester);
    expect(book.mainLineIndex, 4);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await _settleReader(tester);
    expect(book.mainLineIndex, 3);
    expect(lifetime.reader.mainLineIndex, gamePly);
    expect(lifetime.document.editor.hasUnsavedChanges, isFalse);
    // Native window changes can enter fullscreen with a reference tab selected.
    await lifetime.document.presentation.toggleFullScreen();
    await _settleReader(tester);
    expect(lifetime.document.presentation.isFullScreen, isTrue);
    expect(lifetime.reader.mainLineLength, 2);
    expect(book.mainLineIndex, 3);
    expect(
      tester
          .widget<ChessBoardWidget>(find.byType(ChessBoardWidget))
          .position
          .fen,
      lifetime.reader.currentFen,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _settleReader(tester);
    expect(lifetime.reader.mainLineIndex, gamePly + 1);
    expect(book.mainLineIndex, 3);
    expect(
      tester
          .widget<ChessBoardWidget>(find.byType(ChessBoardWidget))
          .position
          .fen,
      lifetime.reader.currentFen,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await _settleReader(tester);
    expect(lifetime.reader.mainLineIndex, gamePly);
    expect(book.mainLineIndex, 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleReader(tester);
    expect(lifetime.document.presentation.isFullScreen, isFalse);
    expect(bookWidget, findsOneWidget);
    expect(book.mainLineIndex, 3);
    expect(
      tester
          .widget<ChessBoardWidget>(find.byType(ChessBoardWidget))
          .position
          .fen,
      book.currentFen,
    );
    await tester.tap(find.byTooltip('Game').first);
    await _settleReader(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _settleReader(tester);
    expect(lifetime.reader.mainLineIndex, gamePly + 1);
    expect(book.mainLineIndex, 3);
    expect(tester.takeException(), isNull);
    await pumpRuntimeWidget(
      tester,
      _engineFixtureSettings!,
      const SizedBox.shrink(),
    );
    await tester.runAsync(lifetime.shutdown);
    await _settleReader(tester);
    await tester.runAsync(
      () => MyRepertoireSettings.instance.setPaths(white: true, paths: []),
    );
  });

  testWidgets(
    'Back restores the live reading cursor after another viewer visit',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = AppState();
      final history = AppHistory(app);
      addTearDown(app.dispose);
      addTearDown(history.dispose);
      app.pushMode(AppMode.pgnViewer, historyLabel: 'Game viewer');
      await pumpRuntimeWidget(
        tester,
        _engineFixtureSettings ??= testRuntimeSettings(),
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
      await _settleReader(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await _settleReader(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _settleReader(tester);
      final reader = tester
          .widget<PgnViewerWidget>(find.byType(PgnViewerWidget))
          .controller!;
      expect(reader.mainLineIndex, 1);
      final previousFen = reader.currentFen;

      app.pushMode(AppMode.tactics, historyLabel: 'Tactics');
      await _settleReader(tester);
      app.pushMode(AppMode.pgnViewer, historyLabel: 'Game viewer');
      await _settleReader(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _settleReader(tester);
      expect(reader.mainLineIndex, 2);

      await tester.runAsync(() async {
        history.popTo(1);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await _settleReader(tester);

      expect(reader.mainLineIndex, 1);
      expect(reader.currentFen, previousFen);
      expect(history.length, 2);
      expect(tester.takeException(), isNull);
      await pumpRuntimeWidget(
        tester,
        _engineFixtureSettings ??= testRuntimeSettings(),
        const SizedBox.shrink(),
      );
      await tester.runAsync(lifetime.shutdown);
      await _settleReader(tester);
    },
  );

  testWidgets(
    'Actions toggles opening details and enters a clear comment editor',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = AppState()..setMode(AppMode.pgnViewer);
      addTearDown(app.dispose);
      await pumpRuntimeWidget(
        tester,
        _engineFixtureSettings ??= testRuntimeSettings(),
        ChangeNotifierProvider.value(
          value: app,
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
      await _settleReader(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await _settleReader(tester);
      expect(find.byType(PgnOpeningLabel), findsNothing);
      expect(find.text('Edit PGN'), findsNothing);
      expect(find.text('PGN'), findsNothing);
      expect(find.text('Main line'), findsNothing);
      await tester.tap(find.text('Actions'));
      await _settleReader(tester);
      expect(find.text('Filter games'), findsWidgets);
      await tester.tap(find.text('Turn autosave off'));
      await _settleReader(tester);
      expect(find.textContaining('Autosave on'), findsNothing);
      await tester.tap(find.text('Actions'));
      await _settleReader(tester);
      expect(find.text('Turn autosave on'), findsOneWidget);
      await tester.tap(find.text('Filter games').last);
      await _settleReader(tester);
      final filters = tester
          .widget<HeaderFilters>(find.byType(HeaderFilters))
          .controller;
      filters.setHeaderField(0, 'White');
      filters.setHeaderValue(0, 'A');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await _settleReader(tester);
      final results = tester.widget<PgnTreeGamesList>(
        find.byType(PgnTreeGamesList),
      );
      results.onGameSelected(0);
      await _settleReader(tester);
      expect(find.byKey(const ValueKey('return-to-filters')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('return-to-filters')));
      await _settleReader(tester);
      expect(
        tester.widget<HeaderFilters>(find.byType(HeaderFilters)).controller,
        same(filters),
      );
      expect(filters.headerRows.single.value, 'A');
      await tester.tap(find.byKey(const ValueKey('apply-game-filters')));
      await _settleReader(tester);
      expect(find.byKey(const ValueKey('return-to-filters')), findsNothing);
      final appliedChip = find.byKey(const ValueKey(('applied-filter', 0)));
      expect(appliedChip, findsOneWidget);
      await tester.tap(appliedChip);
      await _settleReader(tester);
      expect(find.byType(HeaderFilters).hitTestable(), findsOneWidget);
      expect(filters.headerRows.single.value, 'A');
      filters.addHeaderRow(field: 'Black');
      filters.setHeaderValue(1, 'B');
      filters.addHeaderRow(field: 'Opening');
      filters.setHeaderValue(2, 'Orthodox Variation');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await _settleReader(tester);
      await tester.tap(find.byKey(const ValueKey('apply-game-filters')));
      await _settleReader(tester);
      final secondTile = find.byKey(const ValueKey(('applied-filter', 1)));
      final thirdTile = find.byKey(const ValueKey(('applied-filter', 2)));
      expect(tester.getSize(appliedChip), tester.getSize(secondTile));
      expect(tester.getSize(appliedChip), tester.getSize(thirdTile));
      expect(thirdTile.hitTestable(), findsOneWidget);
      expect(
        find.byTooltip('Edit Opening contains Orthodox Variation'),
        findsOneWidget,
      );
      await tester.tap(thirdTile);
      await _settleReader(tester);
      expect(filters.headerRows.last.value, 'Orthodox Variation');
      await tester.tap(find.byKey(const ValueKey('apply-game-filters')));
      await _settleReader(tester);
      await tester.tap(find.byTooltip('Remove White name contains A'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await _settleReader(tester);
      expect(thirdTile, findsNothing);
      expect(
        find.descendant(of: appliedChip, matching: find.text('B')),
        findsOneWidget,
      );
      expect(
        find.byTooltip('Edit Opening contains Orthodox Variation'),
        findsOneWidget,
      );
      await tester.tap(find.text('Actions'));
      await _settleReader(tester);
      await tester.tap(find.text('Show opening'));
      await _settleReader(tester);
      expect(
        find.text('King’s Indian Defense: Orthodox Variation (ECO E94)'),
        findsOneWidget,
      );
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'pgn_viewer.show_opening',
        ),
        isTrue,
      );
      await tester.tap(find.text('Actions'));
      await _settleReader(tester);
      await tester.tap(find.text('Hide opening'));
      await _settleReader(tester);
      expect(find.byType(PgnOpeningLabel), findsNothing);
      await tester.tap(find.text('Actions'));
      await _settleReader(tester);
      await tester.tap(find.text('Edit'));
      await _settleReader(tester);
      expect(find.byType(PgnAnnotationPanel), findsOneWidget);
      expect(find.text('Comment:'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await _settleReader(tester);
      expect(find.byType(PgnAnnotationPanel), findsNothing);
      expect(tester.takeException(), isNull);
      await pumpRuntimeWidget(
        tester,
        _engineFixtureSettings ??= testRuntimeSettings(),
        const SizedBox.shrink(),
      );
      await tester.runAsync(lifetime.shutdown);
      // Let cancellation finish if the background FEN-index isolate was still
      // spawning when the reader was disposed.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await _settleReader(tester);
    },
  );
  testWidgets(
    'cancelled application close retains a PGN approved for discard',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = AppState()..setMode(AppMode.pgnViewer);
      final coordinator = DocumentCloseCoordinator();
      addTearDown(app.dispose);
      addTearDown(coordinator.dispose);
      await pumpRuntimeWidget(
        tester,
        _engineFixtureSettings ??= testRuntimeSettings(),
        ChangeNotifierProvider.value(
          value: app,
          child: DocumentCloseScope(
            coordinator: coordinator,
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: PgnViewerCloseHost(
                lifetime: lifetime,
                child: PgnViewerScreen(lifetime: lifetime),
              ),
            ),
          ),
        ),
      );
      await _settleReader(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settleReader(tester);
      // Pasted content has no durable source even before its first annotation.
      final untouchedClose = coordinator.prepareClose();
      await _settleReader(tester);
      expect(find.text('Save PGN collection'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await _settleReader(tester);
      expect(
        (await untouchedClose).disposition,
        DocumentCloseDisposition.cancelled,
      );
      tester
          .widget<PgnViewerWidget>(find.byType(PgnViewerWidget))
          .onCommentsChanged!('1. d4 {Keep this draft} Nf6 *');
      await _settleReader(tester);
      coordinator.register(
        key: 'other document',
        revision: () => 1,
        prepare: () async => null,
      );
      final close = coordinator.prepareClose();
      await _settleReader(tester);
      expect(find.text('Save PGN collection'), findsOneWidget);
      await tester.tap(find.text('Close without saving'));
      await _settleReader(tester);
      expect((await close).disposition, DocumentCloseDisposition.cancelled);
      expect(
        tester.widget<PgnViewerWidget>(find.byType(PgnViewerWidget)).pgnText,
        contains('Keep this draft'),
      );
      // The next close still asks about the retained work.
      final retry = coordinator.prepareClose();
      await _settleReader(tester);
      expect(find.text('Save PGN collection'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await _settleReader(tester);
      expect((await retry).disposition, DocumentCloseDisposition.cancelled);
      await pumpRuntimeWidget(
        tester,
        _engineFixtureSettings ??= testRuntimeSettings(),
        const SizedBox.shrink(),
      );
      await tester.runAsync(lifetime.shutdown);
      await _settleReader(tester);
    },
  );
}
