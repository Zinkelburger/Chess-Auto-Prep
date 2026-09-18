library;

import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/app/repertoire_dependencies.dart';
import 'package:chess_auto_prep/features/repertoire/services/repertoire_outline_service.dart';

/// Characterization tests for [RepertoireScreen].
///
/// The screen is a large composite with no test coverage of its own, which
/// made every extraction out of it a leap of faith. These tests pin the
/// behaviour a user can see — which layout renders at which width, what the
/// Lines side panel does when collapsed, what survives a restart — so the
/// per-feature extraction underneath can be verified rather than eyeballed.
///
/// The screen loads real files through [StorageFactory], so each test writes a
/// throwaway repertoire folder to a temp directory and drives the screen the
/// way the rest of the app does: an [AppState] handoff.

import 'package:chess_auto_prep/app/builder_lifetime.dart';
import 'package:chess_auto_prep/features/repertoires/models/builder_workspace_snapshot.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import '../support/generation_artifacts_fixture.dart';
import 'package:chess_auto_prep/features/generation/services/generation_artifacts.dart';
import 'package:chess_auto_prep/features/generation/controllers/generation_publication_controller.dart';
import '../support/generation_publication_fixture.dart';

import 'package:chess_auto_prep/infrastructure/repertoires/isolate_repertoire_decoder.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_document_repository.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_decoder.dart';
import '../support/repertoire_dependencies.dart';

import 'package:chess_auto_prep/app/app_dependencies.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/widgets/escape_to_pop_scope.dart';

import 'dart:async';
import 'dart:io';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:chess_auto_prep/services/game_store/game_store_service.dart';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_loading_frame.dart';
import 'package:chess_auto_prep/screens/repertoire_screen.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';

import '../support/board_engine_fixture.dart';

class _TestPaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _TestPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _ChapterCatalog extends LegacyRepertoireCatalogRepository {
  _ChapterCatalog(this.folder)
    : super(
        StorageFactory.instance,
        documents: LegacyPgnDocumentStore(StorageFactory.instance),
      );
  final String folder;
  bool unavailable = false;
  int chapterReads = 0;

  Completer<PgnWriteResult>? chapterCreation;
  bool? createdColor;
  String? createdFolder;
  int creations = 0;
  @override
  Future<PgnWriteResult> createChapter({
    required String folderPath,
    required String name,
    bool? isWhite,
  }) {
    creations++;
    createdColor = isWhite;
    createdFolder = folderPath;
    return chapterCreation?.future ??
        super.createChapter(
          folderPath: folderPath,
          name: name,
          isWhite: isWhite,
        );
  }

  @override
  Future<List<RepertoireMetadata>> listRepertoires() async => [
    RepertoireMetadata(
      filePath: folder,
      name: 'MyRep',
      lastModified: DateTime(2026),
    ),
  ];

  @override
  Future<List<RepertoireMetadata>> listChapters(String folderPath) {
    chapterReads++;
    if (unavailable) throw StateError('Chapter listing unavailable');
    return super.listChapters(folderPath);
  }
}

const _chapterPgn = '''
// Main
// Color: White

[Event "Italian Game"]
[White "Repertoire"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 *
''';

/// Writes `<temp>/MyRep/Main.pgn` and returns the chapter's path.
String _writeRepertoire(WidgetTester tester) {
  final dir = Directory.systemTemp.createTempSync('repertoire_screen_test');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    paths,
    (_) async => dir.path,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      null,
    ),
  );
  final repDir = Directory('${dir.path}/MyRep')..createSync();
  File('${repDir.path}/Main.pgn').writeAsStringSync(_chapterPgn);
  return '${repDir.path}/Main.pgn';
}

/// Loading the repertoire is real file I/O, so the fake async clock alone
/// never finishes it — each cycle lets the I/O run, then paints the result.
Future<void> _settle(WidgetTester tester, {int cycles = 30}) async {
  for (var i = 0; i < cycles; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
}

/// Wait for the asynchronous file/isolate load, not for every ticker on this
/// screen to stop (engine and outline loading indicators may keep animating).
Future<void> _settleUntil(WidgetTester tester, Finder ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (ready.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await _settle(tester, cycles: 1);
  }
  expect(ready, findsWidgets);
}

Future<AppState> _pumpScreen(
  WidgetTester tester, {
  required String repertoirePath,
  Size size = const Size(1600, 1000),
  RepertoireDecoder decoder = const IsolateRepertoireDecoder(),
  BuilderLifetime? restoredLifetime,
  RepertoireCatalogRepository? catalog,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final appState = AppState();
  addTearDown(appState.dispose);
  await pumpCatalogWidget(
    tester,
    MultiProvider(
      providers: [
        Provider<GenerationArtifacts>(
          create: (_) => generationArtifactsFixture(),
        ),
        Provider<GenerationPublicationFactory>(
          create: (_) => generationPublicationFixture,
        ),
        ChangeNotifierProvider<AppState>.value(value: appState),
        Provider<RepertoireOutlineService>(
          create: (context) => createRepertoireOutline(
            catalog: context.read<RepertoireCatalogRepository>(),
            documents: LegacyPgnDocumentStore(StorageFactory.instance),
          ),
        ),
        Provider<RepertoireDocumentRepository>.value(
          value: testRepertoireDocuments(),
        ),
        Provider<RepertoireDecoder>.value(value: decoder),
        Provider<BuilderLifetime>(
          create: (ctx) =>
              restoredLifetime ??
              testBuilderLifetime(
                documents: ctx.read<RepertoireDocumentRepository>(),
                decoder: ctx.read<RepertoireDecoder>(),
              ),
          dispose: (_, lifetime) => lifetime.dispose(),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (_, child) => EscapeToPopScope(child: child!),
        home: const RepertoireScreen(),
      ),
    ),
    catalog: catalog,
  );
  await tester.pump();
  appState.switchToBuilder(repertoirePath: repertoirePath);
  await _settle(tester);
  return appState;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory storageRoot;
  late PathProviderPlatform originalPaths;
  setUp(() async {
    // The storage service serializes directory counts through a Future tail.
    // A tail created by the previous widget test belongs to its fake-async
    // zone; retaining it can leave the next test's outline awaiting forever.
    StorageFactory.instanceForTest = null;
    useScriptedBoardEngine();
    SharedPreferences.setMockInitialValues({});
    storageRoot = await Directory.systemTemp.createTemp(
      'repertoire_screen_storage',
    );
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(storageRoot.path);
    GameStoreService.setTestInstance(GameStoreService());
  });
  tearDown(() async {
    StorageFactory.instanceForTest = null;
    GameStoreService.instance.close();
    PathProviderPlatform.instance = originalPaths;
    if (await storageRoot.exists()) await storageRoot.delete(recursive: true);
  });

  testWidgets('inline chapter creation rejects case-insensitive duplicate', (
    tester,
  ) async {
    final path = _writeRepertoire(tester);
    final catalog = _ChapterCatalog(File(path).parent.path);
    await _pumpScreen(tester, repertoirePath: path, catalog: catalog);
    final document = tester
        .element(find.byType(RepertoireScreen))
        .read<BuilderLifetime>()
        .workspace
        .document;
    await tester.tap(find.byTooltip('Switch chapter'));
    await _settleUntil(tester, find.text('Add chapter'));
    await tester.tap(find.text('Add chapter'));
    await _settle(tester, cycles: 8);
    await tester.enterText(find.byType(TextField).last, 'main');
    await tester.tap(find.text('Create'));
    await _settleUntil(tester, find.text('That chapter already exists.'));
    expect(document.currentRepertoire?.filePath, path);
    expect(File('${File(path).parent.path}/main.pgn').existsSync(), isFalse);
    expect(catalog.creations, 1);
  });

  testWidgets(
    'inline create captures color and rejects completed A B A selection',
    (tester) async {
      final path = _writeRepertoire(tester);
      final catalog = _ChapterCatalog(File(path).parent.path)
        ..chapterCreation = Completer<PgnWriteResult>();
      await _pumpScreen(tester, repertoirePath: path, catalog: catalog);
      final document = tester
          .element(find.byType(RepertoireScreen))
          .read<BuilderLifetime>()
          .workspace
          .document;
      final original = document.currentRepertoire!;
      await tester.tap(find.byTooltip('Switch chapter'));
      await _settleUntil(tester, find.text('Add chapter'));
      await tester.tap(find.text('Add chapter'));
      await _settle(tester, cycles: 8);
      await tester.enterText(find.byType(TextField).last, 'New');
      await tester.tap(find.text('Create'));
      await _settle(tester, cycles: 8);
      expect(catalog.creations, 1);
      expect(catalog.createdColor, isTrue);
      expect(catalog.createdFolder, File(path).parent.path);
      final otherPath = '${File(path).parent.path}/Other.pgn';
      File(
        otherPath,
      ).writeAsStringSync(_chapterPgn.replaceFirst('White', 'Black'));
      unawaited(
        document.setRepertoire(
          RepertoireMetadata(
            filePath: otherPath,
            name: 'Other',
            lastModified: DateTime(2026),
          ),
        ),
      );
      await _settle(tester);
      expect(document.isLoading, isFalse);
      unawaited(document.setRepertoire(original));
      await _settle(tester);
      expect(document.isLoading, isFalse);
      final savedPath = '${File(path).parent.path}/New.pgn';
      File(savedPath).writeAsStringSync('// New\n// Color: White\n');
      catalog.chapterCreation!.complete(
        PgnSaved(
          before: null,
          after: LegacyPgnDocumentStore.snapshot(savedPath, '// New'),
        ),
      );
      await _settle(tester, cycles: 5);
      expect(document.currentRepertoire?.filePath, path);
      expect(catalog.creations, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed copy destination listing retains the draft and retries', (
    tester,
  ) async {
    final path = _writeRepertoire(tester);
    final catalog = _ChapterCatalog(File(path).parent.path)..unavailable = true;
    await _pumpScreen(tester, repertoirePath: path, catalog: catalog);
    final lifetime = tester
        .element(find.byType(RepertoireScreen))
        .read<BuilderLifetime>();
    lifetime.workspace.composeMoves(['d4', 'd5']);
    lifetime.workspace.setTitle('Retained copy');
    await tester.pump();
    final original = File(path).readAsStringSync();
    final previousReads = catalog.chapterReads;
    await tester.tap(find.byKey(const ValueKey('save-builder-draft-copy')));
    await _settleUntil(tester, find.widgetWithText(ListTile, 'MyRep'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(ListTile, 'MyRep'));
    await _settle(tester, cycles: 10);
    expect(catalog.chapterReads, previousReads + 1);
    expect(
      find.text(
        'The draft is retained. Choose a destination and try saving it again.',
      ),
      findsOneWidget,
    );
    expect(
      lifetime.workspace.retainedDrafts.single.content,
      contains('Retained copy'),
    );
    expect(File(path).readAsStringSync(), original);
    expect(tester.takeException(), isNull);
    catalog.unavailable = false;
    await tester.tap(find.byKey(const ValueKey('save-builder-draft-copy')));
    await _settleUntil(tester, find.widgetWithText(ListTile, 'MyRep'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(ListTile, 'MyRep'));
    await _settle(tester);
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (lifetime.workspace.uncertainCopies.any(
          (copy) => lifetime.workspace.copyInProgress(copy.draftKey),
        ) &&
        DateTime.now().isBefore(deadline)) {
      await _settle(tester, cycles: 1);
    }
    expect(catalog.chapterReads, greaterThan(previousReads + 1));
    expect(lifetime.workspace.saveError, isNull);
    expect(
      lifetime.workspace.uncertainCopies.map((copy) => copy.outcome.error),
      isEmpty,
    );
    expect(lifetime.workspace.retainedDrafts, isEmpty);
    expect(File(path).readAsStringSync(), contains('Retained copy'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unreadable source recovery exposes detached editor and save-copy',
    (tester) async {
      final path = _writeRepertoire(tester);
      File(path).deleteSync();
      Directory(path).createSync();
      await _pumpScreen(tester, repertoirePath: path);
      final lifetime = tester
          .element(find.byType(RepertoireScreen))
          .read<BuilderLifetime>();
      await tester.runAsync(
        () => lifetime.workspace.restoreWorkspace(
          BuilderWorkspaceSnapshot(
            drafts: [
              BuilderDraft(
                key: 'unreadable-recovery',
                repertoire: RepertoireMetadata(
                  filePath: path,
                  name: 'Unreadable',
                  lastModified: DateTime(2026),
                ),
                content:
                    '[Event "Recovered scratch"]\n\n1. e4 {retained annotation} e5 *',
                sourcePgn: _chapterPgn,
                lineId: 'original',
                linePgn: _chapterPgn,
                title: 'Recovered scratch',
                cursor: [0],
              ),
            ],
            activeKey: 'unreadable-recovery',
          ),
        ),
      );
      await _settle(tester, cycles: 3);
      expect(find.byType(InteractivePgnEditor), findsOneWidget);
      expect(
        find.byKey(const ValueKey('save-builder-draft-copy')),
        findsOneWidget,
      );
      expect(
        find.textContaining('source changed or is missing'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'first mounted Builder adopts the already restored document outline',
    (tester) async {
      final path = _writeRepertoire(tester);
      final lifetime = testBuilderLifetime();
      await tester.runAsync(
        () => lifetime.workspace.document.setRepertoire(
          RepertoireMetadata(
            filePath: path,
            name: 'Main',
            lastModified: DateTime(2026),
          ),
        ),
      );
      lifetime.workspace.composeMoves(['d4']);
      lifetime.workspace.setTitle('Restored before route');
      await _pumpScreen(
        tester,
        repertoirePath: path,
        restoredLifetime: lifetime,
      );
      await _settleUntil(tester, find.text('Italian Game'));
      expect(find.text('No repertoire open'), findsNothing);
      expect(lifetime.workspace.title, 'Restored before route');
      expect(lifetime.workspace.board.moveHistory, ['d4']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('loaded Builder exposes detached legacy analysis recovery', (
    tester,
  ) async {
    final path = _writeRepertoire(tester);
    await _pumpScreen(tester, repertoirePath: path);
    await _settleUntil(tester, find.text('Italian Game'));
    await tester.tap(find.text('Actions'));
    await _settle(tester, cycles: 3);
    await tester.tap(find.text('Recover generated outputs…'));
    await _settleUntil(
      tester,
      find.text(
        'No saved files were found in this output. Choose another retained output or refresh.',
      ),
    );
    expect(find.text(path), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await _settle(tester, cycles: 3);
    expect(find.text('Italian Game'), findsWidgets);
  });

  testWidgets('library handoff reloads edits to the already open chapter', (
    tester,
  ) async {
    final path = _writeRepertoire(tester);
    final app = await _pumpScreen(tester, repertoirePath: path);
    await _settleUntil(tester, find.text('Italian Game'));
    app.setMode(AppMode.repertoireLibrary);
    File(path).writeAsStringSync(
      _chapterPgn.replaceAll('Italian Game', 'Updated in library'),
    );
    app.handOff(OpenBuilder(repertoirePath: path, reloadFromDisk: true));
    await _settleUntil(tester, find.text('Updated in library'));
    expect(find.text('Italian Game'), findsNothing);
  });

  testWidgets(
    'picker retains builder editor and returns keyboard focus without exposing hidden commands',
    (tester) async {
      await _pumpScreen(tester, repertoirePath: _writeRepertoire(tester));
      final editor = tester.state(find.byType(InteractivePgnEditor));
      await tester.tap(find.text('Actions'));
      await _settle(tester, cycles: 3);
      await tester.tap(find.text('Choose repertoire…'));
      await _settle(tester);
      expect(find.text('Select repertoire'), findsOneWidget);
      expect(find.text('Actions').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Switch mode').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Settings').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Actions'));
      await _settle(tester, cycles: 3);
      expect(find.text('Back to previous view'), findsOneWidget);
      expect(find.text('Plan the lines…'), findsNothing);
      await tester.tap(find.text('Back to previous view'));
      await _settle(tester);
      expect(tester.state(find.byType(InteractivePgnEditor)), same(editor));
      expect(find.text('Italian Game'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('new source handoff waits until the picker closes', (
    tester,
  ) async {
    final path = _writeRepertoire(tester);
    final app = await _pumpScreen(tester, repertoirePath: path);
    await tester.tap(find.text('Actions'));
    await _settle(tester, cycles: 3);
    await tester.tap(find.text('Choose repertoire…'));
    await _settle(tester);
    final next = File('${File(path).parent.path}/Second.pgn')
      ..writeAsStringSync(
        _chapterPgn.replaceAll('Italian Game', 'Second chapter'),
      );
    app.handOff(OpenBuilder(repertoirePath: next.path));
    await _settle(tester);
    expect(app.hasPending<OpenBuilder>(), isTrue);
    expect(find.text('Select repertoire'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await _settleUntil(tester, find.text('Second chapter'));
    expect(app.hasPending<OpenBuilder>(), isFalse);
  });

  group('wide layout', () {
    testWidgets('renders the loaded chapter, its lines, and the side panel', (
      tester,
    ) async {
      await _pumpScreen(tester, repertoirePath: _writeRepertoire(tester));

      // Breadcrumb (repertoire folder, then chapter) and the outline column
      // both name them.
      expect(find.text('MyRep'), findsWidgets);
      expect(find.text('Main'), findsWidgets);

      // The PGN editor is always visible in the wide layout — it is not a tab.
      expect(find.text('PGN'), findsNothing);

      // The outline holds chapters and lines on the left; the analysis panel
      // (Engine | Database | Tree) sits on the right. Both start expanded.
      expect(find.byTooltip('Hide chapters'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Engine'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Database'), findsOneWidget);
      expect(find.text('Reference database'), findsNothing);
      expect(find.text('Notation'), findsNothing);
      expect(find.byTooltip('Analysis panels'), findsNothing);
      expect(find.widgetWithText(Tab, 'Generate'), findsNothing);
      expect(find.byTooltip('Hide analysis panel'), findsOneWidget);

      // The chapter's single line is listed in the outline.
      await _settleUntil(tester, find.text('Italian Game'));
      expect(find.text('Italian Game'), findsOneWidget);
      expect(find.text('Chapters'), findsOneWidget);

      // Board-size control is offered (there is width to trade here).
      expect(find.byTooltip('Board size: Large'), findsOneWidget);
    });

    testWidgets(
      'go to start preserves the selected line for forward navigation',
      (tester) async {
        await _pumpScreen(tester, repertoirePath: _writeRepertoire(tester));
        await _settleUntil(tester, find.text('Italian Game'));
        await tester.tap(find.text('Italian Game'));
        await _settle(tester);
        InteractivePgnEditor editor() =>
            tester.widget(find.byType(InteractivePgnEditor));
        final tree = editor().tree;
        expect(editor().currentPath.isNotEmpty, isTrue);
        await tester.tap(find.byTooltip('Go to start'));
        await tester.pump();
        expect(editor().currentPath.isEmpty, isTrue);
        expect(editor().tree, same(tree));
        expect(editor().isEditingExistingLine, isTrue);
        await tester.tap(find.byTooltip('Forward (→)'));
        await tester.pump();
        expect(editor().currentPath.length, 1);
        expect(editor().tree.sanSequenceAt(editor().currentPath), ['e4']);
      },
    );

    testWidgets('collapsing the analysis panel shows a strip and persists', (
      tester,
    ) async {
      await _pumpScreen(tester, repertoirePath: _writeRepertoire(tester));

      await tester.tap(find.byTooltip('Hide analysis panel'));
      await tester.pump();

      expect(find.byTooltip('Show analysis panel'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Engine'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Database'), findsOneWidget);

      final prefs = await tester.runAsync(SharedPreferences.getInstance);
      expect(prefs!.getBool('repertoire.lines_panel_collapsed'), isTrue);
    });

    testWidgets('collapsing the outline shows a Chapters strip and persists', (
      tester,
    ) async {
      await _pumpScreen(tester, repertoirePath: _writeRepertoire(tester));

      await tester.tap(find.byTooltip('Hide chapters'));
      await tester.pump();

      expect(find.byTooltip('Show chapters'), findsOneWidget);
      expect(find.text('Chapters'), findsOneWidget);
      expect(find.text('Italian Game'), findsNothing);

      final prefs = await tester.runAsync(SharedPreferences.getInstance);
      expect(prefs!.getBool('repertoire.outline_panel_collapsed'), isTrue);
    });

    testWidgets('restores the persisted panel and board size on boot', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'repertoire.lines_panel_collapsed': true,
        'repertoire.board_size': 'small',
      });

      await _pumpScreen(tester, repertoirePath: _writeRepertoire(tester));

      expect(find.byTooltip('Show analysis panel'), findsOneWidget);
      expect(find.byTooltip('Board size: Small'), findsOneWidget);
    });
  });

  testWidgets(
    'short desktop windows retain accessible controls without overflow',
    (tester) async {
      await _pumpScreen(
        tester,
        repertoirePath: _writeRepertoire(tester),
        size: const Size(1280, 500),
      );
      expect(find.byType(InteractivePgnEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  group('compact layout', () {
    testWidgets('stacks the board over PGN | Chapters | Tree tabs', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        repertoirePath: _writeRepertoire(tester),
        size: const Size(900, 1000),
      );

      // All three surfaces become tabs of one tools column.
      expect(find.text('PGN'), findsOneWidget);
      expect(find.text('Chapters'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Database'), findsOneWidget);

      // No side panels, and no board-size control: the board is stacked
      // above the tools, so shrinking it hands width to nothing.
      expect(find.byTooltip('Hide analysis panel'), findsNothing);
      expect(find.byTooltip('Hide chapters'), findsNothing);
      expect(find.byTooltip('Board size: Large'), findsNothing);
    });
  });

  for (final width in [900.0, 1600.0]) {
    testWidgets('Generate opens beside the board at width $width', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        repertoirePath: _writeRepertoire(tester),
        size: Size(width, 1000),
      );
      await tester.tap(find.byTooltip('Generate from here…'));
      await _settle(tester);
      expect(find.widgetWithText(TextFormField, 'Depth'), findsNothing);
      expect(find.widgetWithText(TextFormField, 'Cores'), findsNothing);
      expect(find.widgetWithText(Tab, 'Generate'), findsNothing);
      expect(find.text('Engine evals'), findsOneWidget);
      expect(find.text('Move'), findsOneWidget);
      expect(find.text('Evaluation'), findsOneWidget);
      expect(find.text('Continuation'), findsOneWidget);
      await tester.tap(find.byTooltip('Generation settings'));
      await _settle(tester);
      expect(find.text('Generation settings'), findsWidgets);
      expect(find.text('Depth (half-moves)'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('reference sources switch without hiding board or notation', (
    tester,
  ) async {
    await _pumpScreen(tester, repertoirePath: _writeRepertoire(tester));
    await tester.tap(find.widgetWithText(Tab, 'Database'));
    await _settle(tester);
    await tester.tap(find.byTooltip('Database source'));
    await _settle(tester, cycles: 5);
    await tester.tap(find.text('Opening explorer'));
    await _settle(tester);
    expect(find.byType(InteractivePgnEditor), findsOneWidget);
    expect(find.byTooltip('Go to start'), findsOneWidget);
    await tester.tap(find.byTooltip('Database source'));
    await _settle(tester, cycles: 5);
    await tester.tap(find.text('Repertoire').last);
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'failed reload retains the editor and its draft under a dismissible error',
    (tester) async {
      final decoder = GatedRepertoireDecoder();
      await _pumpScreen(
        tester,
        repertoirePath: _writeRepertoire(tester),
        decoder: decoder,
      );
      await _settleUntil(tester, find.text('Italian Game'));
      await tester.tap(find.text('Italian Game'));
      await _settle(tester);
      final controller = tester
          .element(find.byType(RepertoireScreen))
          .read<BuilderLifetime>()
          .workspace;
      final editor = tester.state(find.byType(InteractivePgnEditor));
      final board = controller.board.tree;
      final current = controller.document.currentRepertoire;
      decoder.afterBuild = () async =>
          throw StateError('Chapter temporarily unavailable');
      unawaited(controller.document.loadRepertoire());
      await _settleUntil(tester, find.byType(MaterialBanner));
      expect(controller.document.currentRepertoire, current);
      expect(controller.board.tree, same(board));
      expect(tester.state(find.byType(InteractivePgnEditor)), same(editor));
      await tester.tap(find.text('Dismiss'));
      await tester.pump();
      expect(find.byType(MaterialBanner), findsNothing);
      expect(tester.state(find.byType(InteractivePgnEditor)), same(editor));
      controller.board.playMove('d3');
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Builder editor copies PGN and edits the workspace title', (
    tester,
  ) async {
    await _pumpScreen(tester, repertoirePath: _writeRepertoire(tester));
    await _settleUntil(tester, find.text('Italian Game'));
    await tester.tap(find.text('Italian Game'));
    await _settle(tester);
    final workspace = tester
        .element(find.byType(RepertoireScreen))
        .read<BuilderLifetime>()
        .workspace;
    final editor = tester.state(find.byType(InteractivePgnEditor));
    await tester.enterText(
      find.widgetWithText(TextField, 'Italian Game'),
      'My Italian preparation',
    );
    await _settle(tester);
    expect(workspace.title, 'My Italian preparation');
    expect(tester.state(find.byType(InteractivePgnEditor)), same(editor));

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final move = find.descendant(
      of: find.byType(InteractivePgnEditor),
      matching: find.byWidgetPredicate((w) => w is MoveChip && w.san == 'e4'),
    );
    await tester.tap(move, buttons: kSecondaryMouseButton);
    await _settle(tester, cycles: 8);
    expect(find.text('View in Lines'), findsOneWidget);
    await tester.tap(find.text('Copy Whole Line'));
    await _settle(tester, cycles: 8);
    expect(copied, contains('e4 e5 2. Nf3 Nc6 3. Bc4'));
    // The shared clipboard helper intentionally keeps successful copies silent.
    expect(find.text('Line copied to clipboard'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reload preserves the board editor while the chapter loads', (
    tester,
  ) async {
    final decoder = GatedRepertoireDecoder();
    await _pumpScreen(
      tester,
      repertoirePath: _writeRepertoire(tester),
      decoder: decoder,
    );
    final controller = tester
        .element(find.byType(RepertoireScreen))
        .read<BuilderLifetime>()
        .workspace;
    await _settleUntil(tester, find.text('Italian Game'));
    await tester.tap(find.text('Italian Game'));
    await _settle(tester);
    expect(PgnAnnotationPanel.focusActive(), isTrue);
    await tester.pump();
    await tester.pump();
    await tester.enterText(
      find.descendant(
        of: find.byType(PgnAnnotationPanel),
        matching: find.byType(TextField),
      ),
      'Save this before reloading',
    );
    final editor = tester.state(find.byType(InteractivePgnEditor));
    final titleField = find.widgetWithText(TextField, 'Italian Game');
    expect(titleField, findsOneWidget);
    final gate = Completer<void>();
    decoder.afterBuild = () => gate.future;
    unawaited(controller.document.loadRepertoire());
    await tester.pump();
    expect(find.text('Loading repertoire...'), findsNothing);
    expect(tester.state(find.byType(InteractivePgnEditor)), same(editor));
    expect(find.byType(LinearProgressIndicator), findsWidgets);
    expect(titleField, findsOneWidget);
    gate.complete();
    // Alternate real I/O and fake-async frames until the load lands. Awaiting
    // this fake-zone future solely inside runAsync cannot advance its queued
    // callbacks and would deadlock the test.
    await _settleUntil(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is RepertoireLoadingFrame && !widget.isLoading,
      ),
    );
    expect(controller.document.isLoading, isFalse);
    expect(
      controller.document.repertoireLines.single.fullPgn,
      contains('Save this before reloading'),
    );
    expect(tester.state(find.byType(InteractivePgnEditor)), same(editor));
    decoder.afterBuild = null;
  });
}

Future<void> pumpCatalogWidget(
  WidgetTester tester,
  Widget child, {
  RepertoireCatalogRepository? catalog,
}) => tester.pumpWidget(
  AppDependencies(repertoireCatalog: catalog, child: child),
);
