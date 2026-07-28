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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/screens/repertoire_screen.dart';

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
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: const MaterialApp(home: RepertoireScreen()),
    ),
  );
  await tester.pump();
  appState.switchToBuilder(repertoirePath: repertoirePath);
  await _settle(tester);
  return appState;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('wide layout', () {
    testWidgets('renders the loaded chapter, its lines, and the side panel', (
      tester,
    ) async {
      await _pumpScreen(tester, repertoirePath: _writeRepertoire(tester));

      // Breadcrumb: repertoire folder, then chapter.
      expect(find.text('MyRep'), findsOneWidget);
      expect(find.text('Main'), findsOneWidget);

      // The PGN editor is always visible in the wide layout — it is not a tab.
      expect(find.text('PGN'), findsNothing);

      // Lines/Tree live in the side panel, which starts expanded.
      expect(find.text('Lines'), findsOneWidget);
      expect(find.text('Tree'), findsOneWidget);
      expect(find.byTooltip('Hide lines (L)'), findsOneWidget);

      // The chapter's single line is listed.
      expect(find.text('Italian Game'), findsOneWidget);
      expect(find.text('1 line'), findsOneWidget);

      // Board-size control is offered (there is width to trade here).
      expect(find.byTooltip('Board size: Large'), findsOneWidget);
    });

    testWidgets('collapsing the Lines panel shows a strip and is persisted', (
      tester,
    ) async {
      await _pumpScreen(tester, repertoirePath: _writeRepertoire(tester));

      await tester.tap(find.byTooltip('Hide lines (L)'));
      await tester.pump();

      expect(find.byTooltip('Show lines (L)'), findsOneWidget);
      // The strip keeps the line count visible.
      expect(find.text('Lines (1)'), findsOneWidget);
      // The tab bar is gone with the panel.
      expect(find.text('Tree'), findsNothing);

      final prefs = await tester.runAsync(SharedPreferences.getInstance);
      expect(prefs!.getBool('repertoire.lines_panel_collapsed'), isTrue);
    });

    testWidgets('restores the persisted panel and board size on boot', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'repertoire.lines_panel_collapsed': true,
        'repertoire.board_size': 'small',
      });

      await _pumpScreen(tester, repertoirePath: _writeRepertoire(tester));

      expect(find.byTooltip('Show lines (L)'), findsOneWidget);
      expect(find.byTooltip('Board size: Small'), findsOneWidget);
    });
  });

  group('compact layout', () {
    testWidgets('stacks the board over PGN | Lines | Tree tabs', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        repertoirePath: _writeRepertoire(tester),
        size: const Size(900, 1000),
      );

      // All three surfaces become tabs of one tools column.
      expect(find.text('PGN'), findsOneWidget);
      expect(find.text('Lines'), findsOneWidget);
      expect(find.text('Tree'), findsOneWidget);

      // No side panel, and no board-size control: the board is stacked above
      // the tools, so shrinking it hands width to nothing.
      expect(find.byTooltip('Hide lines (L)'), findsNothing);
      expect(find.byTooltip('Board size: Large'), findsNothing);
    });
  });

  group('tree tab', () {
    testWidgets('the book toggle reveals the opening explorer', (tester) async {
      await _pumpScreen(tester, repertoirePath: _writeRepertoire(tester));

      await tester.tap(find.text('Tree'));
      await tester.pumpAndSettle();

      expect(find.text('Repertoire tree'), findsOneWidget);
      final book = find.byTooltip('Show Lichess opening explorer');
      expect(book, findsOneWidget);

      await tester.tap(book);
      await tester.pump();

      expect(find.byTooltip('Hide opening explorer'), findsOneWidget);
    });
  });
}
