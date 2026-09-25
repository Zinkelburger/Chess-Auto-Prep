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
library;

import '../support/repertoire_dependencies.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_controller.dart';

import 'package:chess_auto_prep/app/app_dependencies.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/widgets/escape_to_pop_scope.dart';

import 'dart:async';
import 'dart:io';
import 'package:chess_auto_prep/widgets/pgn_with_analysis_pane.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:chess_auto_prep/services/game_store/game_store_service.dart';

import 'package:flutter/material.dart';
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
        ChangeNotifierProvider<AppState>.value(value: appState),
        ChangeNotifierProvider<RepertoireController>(
          create: (_) => testRepertoireController(),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (_, child) => EscapeToPopScope(child: child!),
        home: const RepertoireScreen(),
      ),
    ),
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
  testWidgets('reload preserves the board editor while the chapter loads', (
    tester,
  ) async {
    await _pumpScreen(tester, repertoirePath: _writeRepertoire(tester));
    final controller = tester
        .widget<PgnWithAnalysisPane>(find.byType(PgnWithAnalysisPane))
        .controller;
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
    controller.debugBeforeRepertoireApply = () => gate.future;
    unawaited(controller.loadRepertoire());
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
    expect(controller.isLoading, isFalse);
    expect(
      controller.repertoireLines.single.fullPgn,
      contains('Save this before reloading'),
    );
    expect(tester.state(find.byType(InteractivePgnEditor)), same(editor));
    controller.debugBeforeRepertoireApply = null;
  });
}

Future<void> pumpCatalogWidget(WidgetTester tester, Widget child) =>
    tester.pumpWidget(AppDependencies(child: child));
