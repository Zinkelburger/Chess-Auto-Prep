library;

import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/document_repertoire_repository.dart';
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

import 'package:chess_auto_prep/chess_core/generation/tree_serialization.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import '../services/generation/generation_test_helpers.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/chess_core/generation/trap_line_info.dart';
import 'package:chess_auto_prep/features/generation/models/generation_artifacts.dart';
import 'package:chess_auto_prep/features/traps/widgets/traps_browser.dart';
import 'package:chess_auto_prep/features/traps/widgets/trap_tour_bar.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/widgets/generation/generation_config_form.dart';
import 'package:chess_auto_prep/widgets/repertoire_generation_tab.dart';
import 'package:chess_auto_prep/widgets/engine/floating_board_preview.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';
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

/// Records destructive admission without native filesystem-lock work inside
/// Flutter's fake clock. Reads still use the actual fixture PGN files.
class _DeleteAdmissionRepository extends DocumentRepertoireRepository {
  _DeleteAdmissionRepository()
    : super(LegacyPgnDocumentStore(StorageFactory.instance));

  final deletions = <({String path, Map<int, String> games})>[];

  @override
  Future<int> deleteLinesAt(String path, Map<int, String> expectedGames) async {
    deletions.add((path: path, games: Map.of(expectedGames)));
    return 0;
  }
}

/// Real PGN adapter over immediate disposable file I/O, avoiding native locks
/// whose asynchronous handles do not run on the widget test's fake clock.
class _CutFileStorage implements StorageService {
  int writes = 0;
  bool failWrite = false;
  bool failRefresh = false;
  @override
  Future<String?> readFile(String path) async {
    if (failRefresh && writes > 0) throw StateError('read unavailable');
    return File(path).existsSync() ? File(path).readAsStringSync() : null;
  }

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (failWrite) throw StateError('write unavailable');
    final file = File(path);
    expect(file.readAsStringSync(), expectedContent);
    file.writeAsStringSync(content);
    writes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<RepertoireGenerationTab> _openCutConfiguration(
  WidgetTester tester,
) async {
  await tester.tap(find.byKey(const ValueKey('generation-actions')));
  await _settleUntil(tester, find.text('Cut lines…').hitTestable());
  await tester.tap(find.text('Cut lines…'));
  await _settleUntil(tester, find.byTooltip('Close').hitTestable());
  return tester.widget<RepertoireGenerationTab>(
    find.byType(RepertoireGenerationTab),
  );
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
  GenerationArtifacts? artifacts,
  RepertoireDocumentRepository? documents,
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
          create: (_) => artifacts ?? generationArtifactsFixture(),
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
          value: documents ?? testRepertoireDocuments(),
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
        theme: AppTheme.dark(),
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

  setUpAll(() async {
    // Real desktop typography matters when the trap controls share a toolbar
    // with the chapter picker; Ahem gives those labels different widths.
    for (final entry in {
      'Inter': ['Regular', 'Medium', 'SemiBold', 'Bold', 'Italic'],
      'SourceCodePro': ['Regular', 'Semibold', 'Bold', 'It'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final face in entry.value) {
        loader.addFont(rootBundle.load('assets/fonts/${entry.key}-$face.ttf'));
      }
      await loader.load();
    }
  });

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

  testWidgets(
    'loaded trap artifacts retain browser selection, preview and tour',
    (tester) async {
      final path = _writeRepertoire(tester);
      final trap = TrapLineInfo(
        movesSan: const ['e4', 'e5'],
        fen: fenAfterMoves(kStandardStartFen, const ['e4', 'e5'], 1),
        trapScore: 0.5,
        popularProb: 0.4,
        popularMove: 'Nc3',
        bestMove: 'Nf3',
        popularEvalCp: 150,
        bestEvalCp: 20,
        evalDiffCp: 130,
        cumulativeProb: 0.1,
        trickSurplus: 0.1,
        expectimaxValue: 0.6,
        wpEval: 0.5,
      );
      final repository = MemoryGenerationArtifacts();
      repository.saved[path] = {
        GenerationArtifactKind.traps: jsonEncode({
          'traps': [trap.toJson()],
        }),
      };
      await _pumpScreen(
        tester,
        repertoirePath: path,
        artifacts: GenerationArtifacts(repository),
        size: const Size(950, 1200),
      );
      await tester.tap(find.text('Chapters & Traps'));
      await _settleUntil(
        tester,
        find.byTooltip('Chapter options').hitTestable(),
      );
      await tester.tap(find.byTooltip('Chapter options'));
      await _settleUntil(tester, find.text('Line metrics').hitTestable());
      await tester.tap(find.text('Line metrics'));
      await _settleUntil(tester, find.text('Traps (1)').hitTestable());
      await tester.tap(find.text('Traps (1)'));
      await _settleUntil(tester, find.byType(TrapsBrowser));

      final browser = tester.widget<TrapsBrowser>(find.byType(TrapsBrowser));
      expect(browser.traps.single.movesSan, trap.movesSan);
      expect(browser.metrics, isNotNull);
      expect(
        browser.repertoireLineMoves,
        equals([
          ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4'],
        ]),
      );
      expect(
        tester
            .widgetList<FloatingBoardPreview>(find.byType(FloatingBoardPreview))
            .any(
              (preview) => identical(preview.controller, browser.boardPreview),
            ),
        isTrue,
      );
      final workspace = tester
          .element(find.byType(RepertoireScreen))
          .read<BuilderLifetime>()
          .workspace;
      await tester.tap(
        find.descendant(
          of: find.byType(TrapsBrowser),
          matching: find.text('#1'),
        ),
      );
      await _settle(tester, cycles: 8);
      expect(workspace.board.moveHistory, trap.movesSan);
      expect(workspace.board.fen, trap.fen);
      expect(
        workspace.board.tree
            .nodeAt(workspace.board.path)!
            .children
            .map((node) => node.san),
        containsAll(['Nc3', 'Nf3']),
      );

      await tester.tap(find.text('Chapters & Traps'));
      await _settleUntil(tester, find.text('Start Trap Tour').hitTestable());
      await tester.tap(find.text('Start Trap Tour'));
      await _settle(tester, cycles: 8);
      expect(find.byType(TrapTourBar), findsOneWidget);
      expect(workspace.board.fen, trap.fen);
      final tour = tester.widget<TrapTourBar>(find.byType(TrapTourBar));
      expect(tour.trapIndex.allTraps.single.movesSan, trap.movesSan);
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              (widget.message?.startsWith('Close tour') ?? false),
        ),
      );
      await _settle(tester, cycles: 8);
      expect(find.byType(TrapTourBar), findsNothing);
    },
  );

  testWidgets('manual build opens its preset, cancels, and reopens fresh', (
    tester,
  ) async {
    final path = _writeRepertoire(tester);
    await _pumpScreen(
      tester,
      repertoirePath: path,
      size: const Size(950, 1200),
    );
    final original = File(path).readAsStringSync();
    await tester.tap(find.text('Actions'));
    await _settleUntil(tester, find.text('Generate from here…').hitTestable());
    await tester.tap(find.text('Generate from here…'));
    await _settleUntil(
      tester,
      find.byKey(const ValueKey('generation-actions')).hitTestable(),
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      await tester.tap(find.byKey(const ValueKey('generation-actions')));
      await _settleUntil(
        tester,
        find.byKey(const ValueKey('build-chessdb-repertoire')).hitTestable(),
      );
      await tester.tap(find.byKey(const ValueKey('build-chessdb-repertoire')));
      await _settleUntil(tester, find.byType(GenerationConfigForm));
      await _settleUntil(tester, find.byTooltip('Close').hitTestable());
      final form = tester.state<GenerationConfigFormState>(
        find.byType(GenerationConfigForm),
      );
      final config = form.toConfig(
        startFen: kStandardStartFen,
        playAsWhite: true,
      );
      expect(config.buildMode, BuildMode.chessDbBook);
      expect(config.maxPly, 20);
      expect(config.maxNodes, 12000);
      expect(config.enableChessDbApi, isTrue);
      expect(config.pgnFilePaths, isEmpty);
      expect(
        tester
            .widget<RepertoireGenerationTab>(
              find.byType(RepertoireGenerationTab),
            )
            .generationController
            .isGenerating,
        isFalse,
      );
      if (attempt == 0) {
        await tester.enterText(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                (widget.decoration?.labelText?.startsWith('Branching depth') ??
                    false),
          ),
          '12',
        );
        expect(
          form.toConfig(startFen: kStandardStartFen, playAsWhite: true).maxPly,
          12,
        );
      }
      await tester.tap(find.byTooltip('Close'));
      await _settleUntil(
        tester,
        find.byKey(const ValueKey('generation-actions')).hitTestable(),
      );
      expect(find.byType(GenerationConfigForm), findsNothing);
    }
    expect(File(path).readAsStringSync(), original);
    expect(tester.takeException(), isNull);
  });

  for (final startBuild in [false, true]) {
    for (final returnToA in [false, true]) {
      testWidgets(
        '${startBuild ? 'Build' : 'Cut'} configuration rejects admission after delayed creation'
        '${returnToA ? ' then ABA' : ''}',
        (tester) async {
          final path = _writeRepertoire(tester);
          final originalA = File(path).readAsStringSync();
          final documents = _DeleteAdmissionRepository();
          final catalog = _ChapterCatalog(File(path).parent.path)
            ..chapterCreation = Completer<PgnWriteResult>();
          await _pumpScreen(
            tester,
            repertoirePath: path,
            catalog: catalog,
            documents: documents,
            size: const Size(950, 1200),
          );
          final document = tester
              .element(find.byType(RepertoireScreen))
              .read<BuilderLifetime>()
              .workspace
              .document;
          final chapterA = document.currentRepertoire!;
          final generationA = document.loadGeneration;
          final droppedKey = document.repertoireLines.single.moves.join(' ');

          // A real chapter-creation completion can change the document after
          // its name dialog closes and while a configuration route is open.
          await tester.tap(find.byTooltip('Switch chapter'));
          await _settleUntil(tester, find.text('Add chapter').hitTestable());
          await tester.tap(find.text('Add chapter'));
          await _settleUntil(tester, find.text('Create').hitTestable());
          await tester.enterText(find.byType(TextField).last, 'Other');
          await tester.tap(find.text('Create'));
          await _settle(tester, cycles: 8);
          expect(catalog.creations, 1);
          expect(document.currentRepertoire?.filePath, path);

          await tester.tap(find.text('Actions'));
          await _settleUntil(
            tester,
            find.text('Generate from here…').hitTestable(),
          );
          await tester.tap(find.text('Generate from here…'));
          await _settleUntil(
            tester,
            find.byKey(const ValueKey('generation-actions')).hitTestable(),
          );
          if (startBuild) {
            await tester.tap(find.byKey(const ValueKey('generation-actions')));
            await _settleUntil(
              tester,
              find
                  .byKey(const ValueKey('build-chessdb-repertoire'))
                  .hitTestable(),
            );
            await tester.tap(
              find.byKey(const ValueKey('build-chessdb-repertoire')),
            );
          } else {
            await tester.tap(find.byKey(const ValueKey('generation-actions')));
            await _settleUntil(tester, find.text('Cut lines…').hitTestable());
            await tester.tap(find.text('Cut lines…'));
          }
          await _settleUntil(tester, find.byTooltip('Close').hitTestable());
          final configuration = tester.widget<RepertoireGenerationTab>(
            find.byType(RepertoireGenerationTab),
          );
          expect(configuration.cutOnly, !startBuild);
          expect(configuration.currentRepertoire?.filePath, path);
          expect(configuration.existingLineMoves.map((m) => m.join(' ')), [
            droppedKey,
          ]);

          final otherPath = '${File(path).parent.path}/Other.pgn';
          final originalB = originalA.replaceFirst(
            'Italian Game',
            'Other chapter',
          );
          File(otherPath).writeAsStringSync(originalB);
          catalog.chapterCreation!.complete(
            PgnSaved(
              before: null,
              after: LegacyPgnDocumentStore.snapshot(otherPath, originalB),
            ),
          );
          await _settle(tester);
          expect(document.isLoading, isFalse);
          expect(document.currentRepertoire?.filePath, otherPath);
          expect(document.loadGeneration, greaterThan(generationA));
          if (returnToA) {
            unawaited(document.setRepertoire(chapterA));
            await _settle(tester);
            expect(document.currentRepertoire?.filePath, path);
            expect(document.loadGeneration, greaterThan(generationA + 1));
          }
          expect(find.byType(RepertoireGenerationTab), findsOneWidget);
          final rendered = tester.widget<RepertoireGenerationTab>(
            find.byType(RepertoireGenerationTab),
          );
          expect(
            rendered.currentRepertoire,
            same(configuration.currentRepertoire),
          );
          expect(rendered.fen, configuration.fen);
          expect(rendered.isWhiteRepertoire, configuration.isWhiteRepertoire);
          expect(
            rendered.currentMoveSequence,
            configuration.currentMoveSequence,
          );
          expect(rendered.repertoireStartFen, configuration.repertoireStartFen);
          expect(rendered.existingLineMoves, configuration.existingLineMoves);

          if (startBuild) {
            final controller = configuration.generationController;
            final lastConfig = controller.lastConfig;
            await tester.tap(find.text('Generate Repertoire'));
            await tester.pump();
            expect(controller.currentJob, isNull);
            expect(controller.isGenerating, isFalse);
            expect(controller.lastConfig, same(lastConfig));
            expect(
              find.text(
                'The chapter changed. Close this configuration and open it again.',
              ),
              findsOneWidget,
            );
          } else {
            // The actual route command rejects before the repository boundary.
            expect(await configuration.onTrimLines!({droppedKey}), isNull);
          }
          expect(File(otherPath).readAsStringSync(), originalB);
          expect(File(path).readAsStringSync(), originalA);
          expect(
            document.currentRepertoire?.filePath,
            returnToA ? path : otherPath,
          );
          expect(tester.takeException(), isNull);
          expect(
            documents.deletions,
            isEmpty,
            reason:
                'The retained A configuration must not admit deletion '
                'against the newly loaded document, even when its path returns to A.',
          );
        },
      );
    }
  }

  testWidgets('canceled configuration cannot admit commands after reopening', (
    tester,
  ) async {
    final path = _writeRepertoire(tester);
    final documents = _DeleteAdmissionRepository();
    await _pumpScreen(
      tester,
      repertoirePath: path,
      documents: documents,
      size: const Size(950, 1200),
    );
    await tester.tap(find.text('Actions'));
    await _settleUntil(tester, find.text('Generate from here…').hitTestable());
    await tester.tap(find.text('Generate from here…'));
    await _settleUntil(
      tester,
      find.byKey(const ValueKey('generation-actions')).hitTestable(),
    );
    final old = await _openCutConfiguration(tester);
    final key = old.existingLineMoves.single.join(' ');
    expect(old.createPublicationReceiver(), isNotNull);
    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    expect(old.createPublicationReceiver(), isNull);
    expect(await old.onTrimLines!({key}), isNull);
    await _settleUntil(
      tester,
      find.byKey(const ValueKey('generation-actions')).hitTestable(),
    );
    final current = await _openCutConfiguration(tester);
    expect(current.createPublicationReceiver(), isNotNull);
    expect(old.createPublicationReceiver(), isNull);
    expect(await old.onTrimLines!({key}), isNull);
    final noOp = await current.onTrimLines!({});
    expect(noOp!.removed, 0);
    expect(noOp.remainingMoves, hasLength(1));
    expect(documents.deletions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final outcome in [
    'saved',
    'writeFailure',
    'refreshFailure',
    'sourceChanged',
  ]) {
    testWidgets('visible Cut handles $outcome with refreshed admission', (
      tester,
    ) async {
      final path = _writeRepertoire(tester);
      final helper = StandardTree();
      helper.root.children.remove(helper.d4);
      helper.e4.isRepertoireMove = true;
      helper.e4e5nf3.isRepertoireMove = true;
      helper.e4c5nf3.isRepertoireMove = true;
      final replyFen = playUciMove(helper.e4.fen, 'e7e6')!;
      final reply = makeNode(
        fen: replyFen,
        san: 'e6',
        uci: 'e7e6',
        ply: 2,
        isWhiteToMove: true,
        parent: helper.e4,
        moveProbability: 0.1,
        cumulativeProbability: 0.1,
      );
      makeNode(
        fen: playUciMove(replyFen, 'd2d4')!,
        san: 'd4',
        uci: 'd2d4',
        ply: 3,
        isWhiteToMove: false,
        parent: reply,
        cumulativeProbability: 0.1,
      ).isRepertoireMove = true;
      final tree = helper.toTree()
        ..buildComplete = true
        ..configSnapshot = const TreeBuildConfig(
          startFen: kStandardStartFen,
          playAsWhite: true,
          minProbability: 0.01,
        ).toJson();
      const content =
          '// Color: White\n\n[Event "One"]\n\n1. e4 e5 2. Nf3 *\n\n[Event "Two"]\n\n1. e4 c5 2. Nf3 *\n\n[Event "Three"]\n\n1. e4 e6 2. d4 *\n';
      File(path).writeAsStringSync(content);
      final storage = _CutFileStorage();
      final artifacts = MemoryGenerationArtifacts()
        ..saved[path] = {GenerationArtifactKind.tree: serializeTree(tree)};
      // Native artifact selection is tied to its original source revision.
      // Once Cut changes that source, its global artifact may no longer load.
      artifacts.beforeRead = (_) async {
        if (storage.writes > 0) artifacts.saved.remove(path);
      };
      await _pumpScreen(
        tester,
        repertoirePath: path,
        documents: DocumentRepertoireRepository(
          LegacyPgnDocumentStore(storage),
        ),
        artifacts: GenerationArtifacts(artifacts),
        size: const Size(950, 1200),
      );
      final document = tester
          .element(find.byType(RepertoireScreen))
          .read<BuilderLifetime>()
          .workspace
          .document;
      await tester.tap(find.text('Actions'));
      await _settleUntil(
        tester,
        find.text('Generate from here…').hitTestable(),
      );
      await tester.tap(find.text('Generate from here…'));
      await _settleUntil(
        tester,
        find.byKey(const ValueKey('generation-actions')).hitTestable(),
      );
      final configuration = await _openCutConfiguration(tester);
      await _settleUntil(tester, find.byType(Slider));
      expect(document.repertoireLines, hasLength(3));
      storage.failWrite = outcome == 'writeFailure';
      storage.failRefresh = outcome == 'refreshFailure';
      if (outcome == 'sourceChanged') {
        final other = File('${File(path).parent.path}/Other.pgn')
          ..writeAsStringSync(content);
        unawaited(
          document.setRepertoire(
            RepertoireMetadata(
              name: 'Other',
              filePath: other.path,
              lastModified: DateTime(2026),
            ),
          ),
        );
        await _settle(tester);
      }
      for (final keep in outcome == 'saved' ? [2, 1] : [2]) {
        final slider = tester.widget<Slider>(find.byType(Slider));
        slider.onChanged!(keep.toDouble());
        slider.onChangeEnd!(keep.toDouble());
        await tester.pump();
        expect(find.text('Remove 1 line'), findsOneWidget);
        final before = document.loadGeneration;
        await tester.tap(find.text('Remove 1 line'));
        await _settle(tester);
        if (outcome != 'saved') {
          final message = switch (outcome) {
            'writeFailure' =>
              'The cut could not be confirmed. Reload the chapter before making further changes.',
            'sourceChanged' =>
              'The chapter changed. Close this configuration and open it again.',
            _ =>
              'Removed 1 line, but this configuration could not be refreshed. Reload the chapter before making further changes.',
          };
          expect(find.text(message), findsOneWidget);
          expect(find.byType(Slider), findsNothing);
          expect(find.text('Remove 1 line'), findsNothing);
          expect(storage.writes, outcome == 'refreshFailure' ? 1 : 0);
          if (outcome != 'refreshFailure') {
            expect(File(path).readAsStringSync(), content);
          }
          expect(tester.takeException(), isNull);
          return;
        }
        expect(document.loadGeneration, greaterThan(before));
        expect(document.repertoireLines, hasLength(keep));
        expect(configuration.generationController.generatedTree, isNull);
        expect(find.text('Nothing to remove'), findsOneWidget);
        expect(find.byType(Slider), findsOneWidget);
      }
      expect(storage.writes, 2);
      expect(document.repertoireLines.single.moves, ['e4', 'e5', 'Nf3']);
      expect(File(path).readAsStringSync(), isNot(contains('[Event "Three"]')));
      expect(tester.takeException(), isNull);
    });
  }

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

  for (final selectsLine in [false, true]) {
    testWidgets(
      'superseded ${selectsLine ? 'line' : 'moves'} handoff cannot navigate a newer chapter',
      (tester) async {
        final path = _writeRepertoire(tester);
        final decoder = GatedRepertoireDecoder();
        final app = await _pumpScreen(
          tester,
          repertoirePath: path,
          decoder: decoder,
        );
        final workspace = tester
            .element(find.byType(RepertoireScreen))
            .read<BuilderLifetime>()
            .workspace;
        final pending = File('${File(path).parent.path}/Pending.pgn')
          ..writeAsStringSync(
            _chapterPgn.replaceFirst(
              '[Result "*"]',
              '[LineID "shared-id"]\n[Result "*"]',
            ),
          );
        final newer = File('${File(path).parent.path}/Newer.pgn')
          ..writeAsStringSync(
            _chapterPgn
                .replaceFirst('Italian Game', 'Newer chapter')
                .replaceFirst(
                  '[Result "*"]',
                  '[LineID "shared-id"]\n[Result "*"]',
                )
                .replaceFirst(
                  '1. e4 e5 2. Nf3 Nc6 3. Bc4 *',
                  '1. d4 d5 2. c4 *',
                ),
          );
        final gate = Completer<void>();
        var reads = 0;
        decoder.beforeBuild = () async {
          if (++reads == 1) await gate.future;
        };
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        app.switchToBuilder(
          repertoirePath: pending.path,
          lineId: selectsLine ? 'shared-id' : null,
          moveSequence: selectsLine ? null : ['e4', 'e5'],
        );
        await _settleUntil(
          tester,
          find.byWidgetPredicate(
            (widget) => widget is RepertoireScreen && reads == 1,
          ),
        );
        expect(workspace.document.isLoading, isTrue);
        app.switchToBuilder(repertoirePath: newer.path);
        await _settleUntil(tester, find.text('Newer chapter'));
        expect(workspace.document.currentRepertoire?.filePath, newer.path);
        expect(workspace.document.loadError, isNull);
        gate.complete();
        await _settle(tester, cycles: 3);

        expect(workspace.document.selectedPgnLine, isNull);
        expect(workspace.board.moveHistory, isEmpty);
        expect(workspace.board.fen, kStandardStartFen);
      },
    );
  }

  testWidgets('an A B A handoff drops the first A navigation intent', (
    tester,
  ) async {
    final path = _writeRepertoire(tester);
    final decoder = GatedRepertoireDecoder();
    final app = await _pumpScreen(
      tester,
      repertoirePath: path,
      decoder: decoder,
    );
    final workspace = tester
        .element(find.byType(RepertoireScreen))
        .read<BuilderLifetime>()
        .workspace;
    final a = File(
      '${File(path).parent.path}/A.pgn',
    )..writeAsStringSync(_chapterPgn.replaceFirst('Italian Game', 'Chapter A'));
    final b = File(
      '${File(path).parent.path}/B.pgn',
    )..writeAsStringSync(_chapterPgn.replaceFirst('Italian Game', 'Chapter B'));
    final gates = [Completer<void>(), Completer<void>()];
    var reads = 0;
    decoder.beforeBuild = () async {
      final index = reads++;
      if (index < gates.length) await gates[index].future;
    };
    addTearDown(() {
      for (final gate in gates) {
        if (!gate.isCompleted) gate.complete();
      }
    });
    app.switchToBuilder(repertoirePath: a.path, moveSequence: ['e4', 'e5']);
    await _settleUntil(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is RepertoireScreen && reads == 1,
      ),
    );
    app.switchToBuilder(repertoirePath: b.path);
    await _settleUntil(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is RepertoireScreen && reads == 2,
      ),
    );
    app.switchToBuilder(repertoirePath: a.path);
    await _settleUntil(tester, find.text('Chapter A'));
    expect(workspace.document.currentRepertoire?.filePath, a.path);
    for (final gate in gates) {
      gate.complete();
    }
    await _settle(tester, cycles: 3);
    expect(workspace.board.moveHistory, isEmpty);
    expect(workspace.board.fen, kStandardStartFen);
  });

  testWidgets('a failed handoff load does not navigate the retained chapter', (
    tester,
  ) async {
    final path = _writeRepertoire(tester);
    final decoder = GatedRepertoireDecoder();
    final app = await _pumpScreen(
      tester,
      repertoirePath: path,
      decoder: decoder,
    );
    final workspace = tester
        .element(find.byType(RepertoireScreen))
        .read<BuilderLifetime>()
        .workspace;
    final pending = File('${File(path).parent.path}/Unavailable.pgn')
      ..writeAsStringSync(_chapterPgn);
    final board = workspace.board.tree;
    decoder.beforeBuild = () async => throw StateError('Unavailable chapter');
    app.switchToBuilder(
      repertoirePath: pending.path,
      moveSequence: ['d4', 'd5'],
    );
    await _settleUntil(tester, find.byType(MaterialBanner));
    expect(workspace.document.currentRepertoire?.filePath, path);
    expect(workspace.document.loadError, contains('Unavailable chapter'));
    expect(workspace.board.tree, same(board));
    expect(workspace.board.moveHistory, isEmpty);
  });

  testWidgets(
    'a missing handoff chapter cannot receive a composed move draft',
    (tester) async {
      final path = _writeRepertoire(tester);
      final app = await _pumpScreen(tester, repertoirePath: path);
      final workspace = tester
          .element(find.byType(RepertoireScreen))
          .read<BuilderLifetime>()
          .workspace;
      final missing = '${File(path).parent.path}/Missing.pgn';
      app.switchToBuilder(repertoirePath: missing, moveSequence: ['d4', 'd5']);
      await _settleUntil(
        tester,
        find.byWidgetPredicate(
          (widget) =>
              widget is RepertoireScreen &&
              workspace.document.currentRepertoire?.filePath == missing &&
              !workspace.document.isLoading,
        ),
      );
      expect(workspace.document.repertoirePgn, isNull);
      expect(File(missing).existsSync(), isFalse);
      expect(workspace.board.moveHistory, isEmpty);
      expect(workspace.board.fen, kStandardStartFen);
    },
  );

  testWidgets(
    'ready same-source handoff selects a line then composes without reload',
    (tester) async {
      final path = _writeRepertoire(tester);
      final decoder = GatedRepertoireDecoder();
      final app = await _pumpScreen(
        tester,
        repertoirePath: path,
        decoder: decoder,
      );
      final workspace = tester
          .element(find.byType(RepertoireScreen))
          .read<BuilderLifetime>()
          .workspace;
      final generation = workspace.document.loadGeneration;
      final line = workspace.document.repertoireLines.first;
      decoder.beforeBuild = () async => throw StateError('Unexpected reload');
      app.switchToBuilder(repertoirePath: path, lineId: line.id);
      await _settle(tester, cycles: 2);
      expect(workspace.document.selectedPgnLine, same(line));
      app.switchToBuilder(
        repertoirePath: path,
        lineId: line.id,
        moveSequence: ['d4', 'd5'],
      );
      await _settle(tester, cycles: 2);
      expect(workspace.document.selectedPgnLine, isNull);
      expect(workspace.board.moveHistory, ['d4', 'd5']);
      expect(workspace.document.loadGeneration, generation);
      expect(workspace.document.loadError, isNull);
    },
  );

  testWidgets(
    'same-source pending handoff owns a fresh load and captured moves',
    (tester) async {
      final path = _writeRepertoire(tester);
      final decoder = GatedRepertoireDecoder();
      final app = await _pumpScreen(
        tester,
        repertoirePath: path,
        decoder: decoder,
      );
      final workspace = tester
          .element(find.byType(RepertoireScreen))
          .read<BuilderLifetime>()
          .workspace;
      final gates = [Completer<void>(), Completer<void>()];
      var reads = 0;
      decoder.beforeBuild = () async {
        final index = reads++;
        await gates[index].future;
      };
      addTearDown(() {
        for (final gate in gates) {
          if (!gate.isCompleted) gate.complete();
        }
      });
      var oldFinished = false;
      unawaited(
        workspace.document.loadRepertoire().then((_) => oldFinished = true),
      );
      await _settleUntil(
        tester,
        find.byWidgetPredicate(
          (widget) => widget is RepertoireScreen && reads == 1,
        ),
      );
      final moves = ['e4', 'e5'];
      app.switchToBuilder(repertoirePath: path, moveSequence: moves);
      await _settleUntil(
        tester,
        find.byWidgetPredicate(
          (widget) => widget is RepertoireScreen && reads == 2,
        ),
      );
      moves
        ..clear()
        ..addAll(['d4', 'd5']);
      gates[1].complete();
      await _settleUntil(
        tester,
        find.byWidgetPredicate(
          (widget) =>
              widget is RepertoireScreen && !workspace.document.isLoading,
        ),
      );
      expect(workspace.board.moveHistory, ['e4', 'e5']);
      gates[0].complete();
      await _settleUntil(
        tester,
        find.byWidgetPredicate(
          (widget) => widget is RepertoireScreen && oldFinished,
        ),
      );
      expect(workspace.board.moveHistory, ['e4', 'e5']);
      expect(workspace.document.loadError, isNull);
    },
  );

  testWidgets('leaving Builder while a handoff loads suppresses navigation', (
    tester,
  ) async {
    final path = _writeRepertoire(tester);
    final decoder = GatedRepertoireDecoder();
    final app = await _pumpScreen(
      tester,
      repertoirePath: path,
      decoder: decoder,
    );
    final workspace = tester
        .element(find.byType(RepertoireScreen))
        .read<BuilderLifetime>()
        .workspace;
    final pending = File('${File(path).parent.path}/Pending.pgn')
      ..writeAsStringSync(_chapterPgn);
    final gate = Completer<void>();
    var entered = false;
    decoder.beforeBuild = () async {
      entered = true;
      await gate.future;
    };
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    app.switchToBuilder(
      repertoirePath: pending.path,
      moveSequence: ['e4', 'e5'],
    );
    await _settleUntil(
      tester,
      find.byWidgetPredicate((widget) => widget is RepertoireScreen && entered),
    );
    app.setMode(AppMode.pgnViewer);
    gate.complete();
    await _settleUntil(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is RepertoireScreen && !workspace.document.isLoading,
      ),
    );
    expect(app.currentMode, AppMode.pgnViewer);
    expect(workspace.document.currentRepertoire?.filePath, pending.path);
    expect(workspace.board.moveHistory, isEmpty);
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
      expect(find.text('Expected'), findsOneWidget);
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
