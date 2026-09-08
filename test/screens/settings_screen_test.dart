import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/models/board_display_settings.dart';
import 'package:chess_auto_prep/models/engine_settings.dart';
import 'package:chess_auto_prep/models/eval_database_settings.dart';
import 'package:chess_auto_prep/screens/settings_screen.dart';
import 'package:chess_auto_prep/widgets/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpSettings(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>(
        create: (_) => AppState(),
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('navigation shows one section and preserves account edits', (
    tester,
  ) async {
    await pumpSettings(tester, const Size(1280, 720));
    expect(find.text('Your chess usernames'), findsOneWidget);
    expect(find.text('CPU cores'), findsNothing);
    await tester.tap(find.text('Use a personal access token instead'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'unsaved-token');

    await tester.tap(find.byKey(const Key('settings-nav-3')));
    await tester.pumpAndSettle();
    expect(find.text('CPU cores'), findsOneWidget);
    expect(find.text('Your chess usernames'), findsNothing);

    await tester.tap(find.byKey(const Key('settings-nav-0')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'unsaved-token'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short window can scroll to reset and cancel safely', (
    tester,
  ) async {
    await pumpSettings(tester, const Size(800, 360));
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-nav-5')),
      60,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const Key('settings-nav-5')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-nav-5')));
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
    final cores = EngineSettings.instance.cores;
    await tester.tap(find.text('Reset settings…'));
    await tester.pumpAndSettle();
    expect(find.text('Reset Settings'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(EngineSettings.instance.cores, cores);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow windows expose every category and usable engine controls',
    (tester) async {
      await pumpSettings(tester, const Size(400, 640));
      for (final section in [
        'Display',
        'Repertoires',
        'Engine',
        'Data',
        'About',
        'Accounts',
      ]) {
        // The picker is a text box: type part of the name, Enter takes the
        // top match.
        await tester.enterText(
          find.byKey(const Key('settings-section-picker')),
          section.substring(0, 3),
        );
        await tester.pumpAndSettle();
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: section);
        if (section == 'Engine') {
          expect(find.text('CPU cores'), findsOneWidget);
          expect(find.text('Memory per engine'), findsOneWidget);
          expect(find.byType(SettingsStepperTile), findsNWidgets(3));
        }
      }
    },
  );

  testWidgets(
    'data preferences persist and the databases link returns to the app',
    (tester) async {
      final app = AppState();
      addTearDown(app.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsScreen(),
                    ),
                  ),
                  child: const Text('Open settings'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-nav-4')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Years of games'), findsNothing);
      expect(find.textContaining('ChessDB data directory'), findsNothing);
      final settings = EvalDatabaseSettings.instance;
      final before = settings.chessDbApiForExpectimax;
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(settings.chessDbApiForExpectimax, !before);
      await settings.setChessDbApiForExpectimax(before);
      await tester.tap(find.text('Open Databases'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      expect(app.currentMode, AppMode.databases);
    },
  );

  testWidgets('display preferences change the live preview and persist', (
    tester,
  ) async {
    addTearDown(() => BoardDisplaySettings.instance.resetToDefaults());
    await pumpSettings(tester, const Size(1280, 720));
    await tester.tap(find.byKey(const Key('settings-nav-1')));
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
    expect(
      BoardDisplaySettings.instance.pieceNotation,
      PieceNotation.figurines,
    );

    await tester.tap(find.text('Inside the board'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Every square').last);
    await tester.pumpAndSettle();
    expect(
      BoardDisplaySettings.instance.coordinates,
      BoardCoordinates.everySquare,
    );
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
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>(
        create: (_) => AppState(),
        child: MaterialApp(
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
