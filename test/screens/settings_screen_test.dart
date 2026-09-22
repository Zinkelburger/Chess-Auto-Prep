import '../support/runtime_settings.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/features/settings/models/board_display_configuration.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

RuntimeSettings? _runtimeSettings;
RuntimeSettings get runtimeSettings =>
    _runtimeSettings ??= RuntimeSettings.preferences();
void main() {
  setUp(() {
    _runtimeSettings = null;
    addTearDown(() => _runtimeSettings?.dispose());
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpSettings(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpRuntimeWidget(
      tester,
      runtimeSettings,
      ChangeNotifierProvider<AppState>(
        create: (_) => AppState(),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectGlobal(WidgetTester tester, Finder finder) async {
    await tester.drag(
      find.descendant(
        of: find.byKey(const Key('settings-navigation')),
        matching: find.byType(Scrollable),
      ),
      const Offset(0, 1400),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      finder,
      180,
      scrollable: find.descendant(
        of: find.byKey(const Key('settings-navigation')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
  }

  testWidgets('flat sections preserve drafts and do not switch workspaces', (
    tester,
  ) async {
    await pumpSettings(tester, const Size(1280, 720));
    final app = tester.element(find.byType(SettingsScreen)).read<AppState>();
    final origin = app.currentMode;
    expect(find.text('VIEWS'), findsNothing);
    expect(find.text('GLOBAL'), findsNothing);
    await tester.enterText(
      find.byKey(const Key('lichess-username-field')),
      'draft-name',
    );
    await tester.tap(find.byKey(const Key('settings-nav-3')));
    await tester.pumpAndSettle();
    expect(find.text('Board analysis depth'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-view-repertoireTrainer')));
    await tester.pumpAndSettle();
    expect(app.currentMode, origin);
    expect(find.text('Loading settings…'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-nav-0')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('lichess-username-field')))
          .controller!
          .text,
      'draft-name',
    );
    expect(app.lichessUsername, isNull);
    await tester.tap(find.byKey(const Key('accounts-save-button')));
    await tester.pumpAndSettle();
    expect(app.lichessUsername, 'draft-name');
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Study gear lands on shared analysis controls', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpRuntimeWidget(
      tester,
      runtimeSettings,
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SettingsScreen(initialMode: AppMode.study),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Board analysis depth'), findsOneWidget);
    expect(find.byKey(const Key('settings-chapter-study-0')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard reference displays shared mappings and is scrollable', (
    tester,
  ) async {
    await pumpSettings(tester, const Size(1280, 720));
    await selectGlobal(tester, find.byKey(const Key('settings-nav-6')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Focus variation'),
      250,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('settings-page-6')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Enter'), findsWidgets);
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('Action'), findsOneWidget);
    expect(find.text('Key'), findsOneWidget);
    expect(find.text('Where'), findsOneWidget);
    expect(find.text('Ctrl+1'), findsNothing);
    expect(find.text('Switch view'), findsNothing);
    expect(find.text('Flip board'), findsOneWidget);
    expect(find.text('Ctrl+Enter'), findsNothing);
    expect(find.text('Ctrl+←'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short window can scroll to reset and cancel safely', (
    tester,
  ) async {
    await pumpSettings(tester, const Size(800, 360));
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-nav-5')),
      60,
      scrollable: find.descendant(
        of: find.byKey(const Key('settings-navigation')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.ensureVisible(find.byKey(const Key('settings-nav-5')));
    await tester.pumpAndSettle();
    await selectGlobal(tester, find.byKey(const Key('settings-nav-5')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Reset settings…'),
      180,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey('settings-page-5')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    final cores = runtimeSettings.engine.cores;
    await tester.tap(find.text('Reset settings…'));
    await tester.pumpAndSettle();
    expect(
      find.text('Reset analysis, board and data preferences?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(runtimeSettings.engine.cores, cores);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow settings find sections by control name', (tester) async {
    await pumpSettings(tester, const Size(400, 700));
    final search = find.widgetWithText(TextField, 'Find a setting');
    await tester.enterText(search, 'memory');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-nav-3')));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byKey(const Key('engine-board-depth')),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '19');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(runtimeSettings.engine.depth, 19);
    await tester.enterText(search, 'coordinates');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-nav-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('display-preview-board')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('display preferences change the live preview and persist', (
    tester,
  ) async {
    await pumpSettings(tester, const Size(1280, 720));
    await selectGlobal(tester, find.byKey(const Key('settings-nav-1')));
    await tester.pumpAndSettle();
    expect(find.text('Board coordinates'), findsOneWidget);
    expect(find.text('Piece notation'), findsOneWidget);
    expect(find.byKey(const Key('display-preview-board')), findsOneWidget);

    Text previewLine() =>
        tester.widget<Text>(find.byKey(const Key('display-preview-line')));
    expect(previewLine().data, contains('Nf3'));

    await tester.tap(find.text('Letters (KQRBN)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Figurines (♔♕♖♗♘)').last);
    await tester.pumpAndSettle();
    expect(previewLine().data, contains('♘f3'));
    expect(runtimeSettings.display.pieceNotation, PieceNotation.figurines);

    await tester.tap(find.text('Inside the board'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Every square').last);
    await tester.pumpAndSettle();
    expect(runtimeSettings.display.coordinates, BoardCoordinates.everySquare);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('display.board_coordinates'), 'everySquare');
    expect(tester.takeException(), isNull);
  });

  testWidgets('close sits top-right where the gear was and pops the route', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpRuntimeWidget(
      tester,
      runtimeSettings,
      ChangeNotifierProvider<AppState>(
        create: (_) => AppState(),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final close = find.byTooltip('Close settings (Esc)');
    expect(close, findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(tester.getCenter(close).dx, greaterThan(1280 * 0.9));

    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
