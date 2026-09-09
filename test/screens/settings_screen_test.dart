import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/models/training_settings.dart';
import 'package:chess_auto_prep/widgets/training/training_settings_panel.dart';
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

  Future<void> selectGlobal(WidgetTester tester, Finder finder) async {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 1400));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      finder,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
  }

  testWidgets('trainer chapters stay inside one shared settings shell', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = TrainingSettings();
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: MaterialApp(
          home: SettingsScreen(
            initialMode: AppMode.repertoireTrainer,
            viewContentBuilder: (_) => TrainingSettingsPanel(
              settings: settings,
              trainingMode: TrainingMode.repertoire,
              repetitionMode: RepetitionMode.spaced,
              onQueueSettingsChanged: () {},
              onSettingsChanged: () {},
              onTrainingModeChanged: (_) {},
              onRepetitionModeChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('New lines'), findsOneWidget);
    expect(find.byKey(const Key('training-settings-nav-0')), findsNothing);
    expect(find.byKey(const Key('settings-view-tactics')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('New lines')), '12');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('settings-chapter-repertoireTrainer-1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('New lines'), findsNothing);
    expect(find.byKey(const Key('training-depth')), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('settings-chapter-repertoireTrainer-2')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('training-depth')), findsNothing);
    await tester.tap(
      find.byKey(const Key('settings-chapter-repertoireTrainer-0')),
    );
    await tester.pumpAndSettle();
    expect((await TrainingSettings.load()).newLinesPerSession, 12);
    expect(find.text('12'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('navigation shows one section and preserves account edits', (
    tester,
  ) async {
    await pumpSettings(tester, const Size(1280, 720));
    expect(find.text('Your chess usernames'), findsOneWidget);
    expect(find.text('CPU cores'), findsNothing);
    await tester.tap(find.text('Use a personal access token instead'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'unsaved-token');

    await selectGlobal(tester, find.byKey(const Key('settings-nav-3')));
    await tester.pumpAndSettle();
    expect(find.text('Cores'), findsOneWidget);
    expect(find.text('Your chess usernames'), findsNothing);

    await selectGlobal(tester, find.byKey(const Key('settings-nav-0')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'unsaved-token'), findsOneWidget);
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
      scrollable: find.byType(Scrollable).first,
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
        'Keyboard shortcuts',
        'Accounts',
      ]) {
        // The picker is a text box: type part of the name, Enter takes the
        // top match.
        await tester.enterText(
          find.byKey(const Key('settings-section-picker')),
          'Global · $section',
        );
        await tester.pumpAndSettle();
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: section);
        if (section == 'Engine') {
          expect(find.text('Cores'), findsOneWidget);
          expect(find.text('Memory (MB)'), findsOneWidget);
          expect(find.text('Board depth'), findsOneWidget);
          expect(find.text('Bulk depth'), findsOneWidget);
          expect(find.text('Search'), findsNothing);
          expect(find.text('Review performance'), findsNothing);
          expect(find.byKey(const Key('settings-nav-7')), findsNothing);
          expect(find.byType(SettingsStepperTile), findsOneWidget);
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
      await selectGlobal(tester, find.byKey(const Key('settings-nav-4')));
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
