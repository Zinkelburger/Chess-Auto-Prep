/// The Play block: what is playable, and the button that plays it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/widgets/app_settings_button.dart';
import 'package:chess_auto_prep/widgets/settings/settings_navigation.dart';
import 'package:chess_auto_prep/features/tactics/widgets/tactics_session_settings_form.dart';
import 'package:chess_auto_prep/features/tactics/models/tactics_position.dart';
import 'package:chess_auto_prep/features/tactics/models/tactics_session_settings.dart';
import 'package:chess_auto_prep/features/tactics/controllers/tactics_session_controller.dart';
import 'package:chess_auto_prep/features/tactics/widgets/tactics_import_panel.dart';

import 'package:chess_auto_prep/features/games/controllers/recent_games_controller.dart';
import 'package:chess_auto_prep/features/games/services/home_review_runner.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_import_coordinator.dart';
import 'package:chess_auto_prep/features/tactics/widgets/tactics_view_settings.dart';
import 'package:chess_auto_prep/models/engine_settings.dart';

/// A puzzle mined today, so no expiry window can filter it out.
TacticsPosition _position({required String id, String mistakeType = '??'}) {
  final now = DateTime.now();
  final date =
      '${now.year}.${now.month.toString().padLeft(2, '0')}.'
      '${now.day.toString().padLeft(2, '0')}';
  return TacticsPosition(
    fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    userMove: 'a3',
    correctLine: const ['e4'],
    mistakeType: mistakeType,
    mistakeAnalysis: 'test',
    gameWhite: 'A',
    gameBlack: 'B',
    gameResult: '1-0',
    gameDate: date,
    gameId: id,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<TacticsSessionController> pumpPanel(
    WidgetTester tester, {
    required List<TacticsPosition> positions,
    bool isImporting = false,
  }) async {
    final session = TacticsSessionController();
    addTearDown(session.dispose);
    // Never expire, so the fixtures stay playable.
    session.setSessionSettings(
      const TacticsSessionSettings().copyWith(clearMaxAgeDays: true),
      save: false,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>(create: (_) => AppState()),
          ChangeNotifierProvider<TacticsSessionController>.value(
            value: session,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                AppSettingsButton(
                  mode: AppMode.tactics,
                  contentBuilder: (context) => ListenableBuilder(
                    listenable: session,
                    builder: (context, _) => ListView(
                      padding: const EdgeInsets.all(24),
                      children: [
                        TacticsSessionSettingsForm(
                          settings: session.sessionSettings,
                          showCustomType: true,
                          section: SettingsChapterScope.maybeOf(context) == 0
                              ? TacticsSettingsSection.session
                              : TacticsSettingsSection.selection,
                          onChanged: session.setSessionSettings,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            body: SingleChildScrollView(
              child: TacticsImportPanel(
                isImporting: isImporting,
                positions: positions,
                onBrowseTactics: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return session;
  }

  testWidgets('the count and the button that plays it are on one card', (
    tester,
  ) async {
    final started = <int>[];
    final session = await pumpPanel(
      tester,
      positions: [
        _position(id: '1'),
        _position(id: '2'),
        _position(id: '3', mistakeType: '?'),
      ],
    );
    session.attachPanel(TacticsPanelHooks(start: () => started.add(1)));
    await tester.pump();

    expect(
      find.textContaining('Ready to play: 2 blunders, 1 mistake'),
      findsOneWidget,
    );
    // The verb for that sentence is right underneath it, carrying the same
    // number — not on the far side of the screen.
    expect(find.text('Play tactics (3)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('play-tactics-button')));
    expect(started, hasLength(1));
  });

  testWidgets('it stays pressable while the analysis is still running', (
    tester,
  ) async {
    await pumpPanel(tester, positions: [_position(id: '1')], isImporting: true);

    expect(
      find.textContaining('more are added as the review finds them'),
      findsOneWidget,
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('play-tactics-button')),
    );
    expect(
      button.onPressed,
      isNotNull,
      reason: 'you play what has been mined so far while the rest arrives',
    );
  });

  testWidgets('with nothing mined it is dead, and says the analysis is on', (
    tester,
  ) async {
    await pumpPanel(tester, positions: const [], isImporting: true);

    expect(
      find.textContaining('Analysing your games'),
      findsOneWidget,
      reason: 'auto-start means the usual empty database is a busy one',
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('play-tactics-button')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('Play tactics'), findsOneWidget);
  });

  testWidgets('expiry is a number you type, with Never as its own box', (
    tester,
  ) async {
    final session = await pumpPanel(
      tester,
      positions: [_position(id: '1')],
      isImporting: false,
    );

    await tester.tap(find.text('Filters…'));
    await tester.pumpAndSettle();

    const field = Key('tactics-expiry-days-field');
    expect(find.text('Tactics expire after'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(field)).controller!.text,
      '${session.sessionSettings.maxAgeDays}',
      reason: 'the box opens showing the window in force',
    );

    await tester.enterText(find.byKey(field), '30');
    await tester.pump();
    await tester.tap(find.byTooltip('Close settings (Esc)'));
    await tester.pumpAndSettle();

    expect(session.sessionSettings.maxAgeDays, 30);
  });

  testWidgets('Never expire empties the window and greys the box', (
    tester,
  ) async {
    final session = await pumpPanel(
      tester,
      positions: [_position(id: '1')],
      isImporting: false,
    );

    await tester.tap(find.text('Filters…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Never expire'));
    await tester.pump();

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tactics-expiry-days-field')))
          .enabled,
      isFalse,
      reason: 'a number that governs nothing should not be typeable',
    );

    await tester.tap(find.byTooltip('Close settings (Esc)'));
    await tester.pumpAndSettle();
    expect(session.sessionSettings.maxAgeDays, isNull);
  });

  testWidgets('a half-typed expiry box does not clear the setting', (
    tester,
  ) async {
    final session = await pumpPanel(
      tester,
      positions: [_position(id: '1')],
      isImporting: false,
    );

    await tester.tap(find.text('Filters…'));
    await tester.pumpAndSettle();

    const field = Key('tactics-expiry-days-field');
    await tester.enterText(find.byKey(field), '30');
    await tester.pump();
    await tester.enterText(find.byKey(field), '');
    await tester.pump();
    await tester.tap(find.byTooltip('Close settings (Esc)'));
    await tester.pumpAndSettle();

    expect(
      session.sessionSettings.maxAgeDays,
      30,
      reason: 'an empty box is mid-edit, not "expire after zero days"',
    );
  });
  testWidgets('Analysis gear opens cores and saved values reach the runner', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final before = EngineSettings.instance.cores;
    addTearDown(() => EngineSettings.instance.cores = before);
    EngineSettings.instance.cores = 1;
    final session = TacticsSessionController();
    final games = RecentGamesController(
      lichessUsername: () => null,
      chesscomUsername: () => null,
    );
    final coordinator = TacticsImportCoordinator();
    final runner = HomeReviewRunner(
      games: games,
      importCoordinator: coordinator,
      lichessUsername: () => null,
      chesscomUsername: () => null,
    );
    addTearDown(session.dispose);
    addTearDown(games.dispose);
    addTearDown(coordinator.dispose);
    addTearDown(runner.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AppState()),
          ChangeNotifierProvider.value(value: session),
          ChangeNotifierProvider.value(value: games),
          ChangeNotifierProvider.value(value: coordinator),
          ChangeNotifierProvider.value(value: runner),
        ],
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                AppSettingsButton(
                  mode: AppMode.tactics,
                  contentBuilder: (_) => TacticsViewSettings(
                    session: session,
                    games: games,
                    runner: runner,
                  ),
                ),
              ],
            ),
            body: SingleChildScrollView(
              child: TacticsImportPanel(
                isImporting: false,
                positions: const [],
                onBrowseTactics: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Engine settings'));
    await tester.pumpAndSettle();
    final cores = find.byKey(const Key('engine-cores'));
    expect(cores, findsOneWidget);
    expect(find.byKey(const Key('engine-bulk-depth')), findsOneWidget);
    expect(find.byKey(const Key('book-check-games-field')), findsNothing);
    await tester.enterText(
      find.descendant(of: cores, matching: find.byType(TextField)),
      '2',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final expected = EngineSettings.systemCores > 1 ? 2 : 1;
    expect(runner.cores, expected);
    await tester.tap(find.byTooltip('Engine settings'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('review-cores-readout'))).data,
      '$expected ${expected == 1 ? 'core' : 'cores'}',
    );
  });
}
