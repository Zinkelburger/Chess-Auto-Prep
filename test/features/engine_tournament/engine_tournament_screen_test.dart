import 'dart:io';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/engine_tournament/controllers/engine_tournament_controller.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/engine_spec.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/stored_tournament.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/tournament_config.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/tournament_game.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/tournament_store.dart';
import 'package:chess_auto_prep/features/engine_tournament/widgets/engine_tournament_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

const _fen = '3r2k1/p4p2/7p/3pB1p1/8/P3P2P/1P3PP1/6K1 b - - 0 1';

/// Two frames: one to build, one to settle the first `notifyListeners`.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late AppState appState;
  late EngineTournamentController controller;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('engine_tournament_screen');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    SharedPreferences.setMockInitialValues({});
    appState = AppState()
      // The app-bar title is the mode switcher, which names the *current*
      // mode — so a standalone screen test has to be in that mode.
      ..setMode(AppMode.engineTournament);
    controller = EngineTournamentController();
  });

  tearDown(() async {
    controller.dispose();
    appState.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    // Initialised here rather than by the screen: see
    // [EngineTournamentScreen.controller].
    await tester.runAsync(controller.initialize);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: MaterialApp(
          // `showAppSnackBar` sets an explicit width, which Material asserts
          // is only legal for a floating snackbar — the real app's theme says
          // so, and a bare MaterialApp here would not.
          theme: ThemeData(
            snackBarTheme: const SnackBarThemeData(
              behavior: SnackBarBehavior.floating,
            ),
          ),
          home: EngineTournamentScreen(controller: controller),
        ),
      ),
    );
    // The controller reads the tournaments directory on init. Real file I/O
    // does not complete inside the fake-async zone `testWidgets` runs in, so
    // it needs `runAsync` — and a spinner is on screen until it lands, which
    // is also why this cannot be `pumpAndSettle`.
    await _settle(tester);
  }

  Future<StoredTournament> seedTournament({
    String name = 'Seeded match',
  }) async {
    final store = TournamentStore(
      Directory(p.join(temp.path, kEngineTournamentsDirectoryName)),
    );
    final created = await store.create(
      TournamentConfig(
        name: name,
        startFen: _fen,
        openingLabel: 'Rook vs bishop',
        gamesPerPairing: 2,
        engines: const [
          EngineSpec(id: 'a', name: 'Alpha', executablePath: '/bin/a'),
          EngineSpec(id: 'b', name: 'Beta', executablePath: '/bin/b'),
        ],
      ),
    );
    final finished = created.copyWith(
      status: TournamentStatus.completed,
      games: [
        TournamentGameRecord(
          gameIndex: 0,
          round: 1,
          whiteIndex: 0,
          blackIndex: 1,
          whiteName: 'Alpha',
          blackName: 'Beta',
          result: GameResult.blackWins,
          termination: TerminationReason.resignAdjudication,
          plies: 76,
          startedAt: DateTime(2026, 8, 22),
          durationMs: 152000,
        ),
      ],
    );
    await store.save(finished);
    return finished;
  }

  testWidgets('with nothing saved it offers to start one', (tester) async {
    await pumpScreen(tester);
    expect(find.text('Engine tournament'), findsOneWidget);
    expect(find.text('No tournaments yet'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'New tournament'), findsWidgets);
  });

  testWidgets('a saved tournament shows its crosstable and games', (
    tester,
  ) async {
    await tester.runAsync(seedTournament);
    await pumpScreen(tester);

    expect(find.text('Seeded match'), findsWidgets);
    expect(find.text('Crosstable'), findsOneWidget);
    expect(find.text('Games'), findsOneWidget);
    // One game played of two scheduled.
    expect(find.text('1/2 games'), findsOneWidget);
    expect(find.text('0-1'), findsOneWidget);
    expect(find.textContaining('Adjudicated win'), findsOneWidget);
  });

  testWidgets('clicking a game hands it to the PGN Viewer', (tester) async {
    final seeded = (await tester.runAsync(seedTournament))!;
    await pumpScreen(tester);

    await tester.tap(find.text('0-1'));
    await tester.pump();

    // The handoff carries the app to the viewer and parks the file there.
    expect(appState.currentMode, AppMode.pgnViewer);
    final handoff = appState.takeHandoff<OpenPgnViewer>();
    expect(handoff, isNotNull);
    expect(handoff!.pgnPath, seeded.pgnPath);
    // The whole match stays loaded, parked on this game, so Prev/Next in the
    // viewer walk the rest of it.
    expect(handoff.gameIndex, 0);
    expect(handoff.gameId, isNull);
  });

  testWidgets('the starting position can be copied back out as a FEN', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
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

    await tester.runAsync(seedTournament);
    await pumpScreen(tester);

    // The position chip is labelled with the opening, not the FEN — clicking
    // it is how you get the FEN itself.
    await tester.tap(find.text('Rook vs bishop'));
    await tester.pump();

    expect(copied, [_fen]);
  });

  testWidgets('an open request from outside selects that tournament', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await seedTournament(name: 'First match');
      await seedTournament(name: 'Second match');
    });
    await pumpScreen(tester);
    // Newest first, so the second one is what the screen shows unasked.
    expect(find.text('Second match'), findsWidgets);

    // What the MCP `tournament_open` tool ultimately causes. Delivered
    // inside runAsync so the re-read it may trigger can touch the disk.
    await tester.runAsync(() async {
      appState.switchToEngineTournament(tournamentId: 'first-match');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await _settle(tester);

    expect(controller.selected?.id, 'first-match');
    expect(find.text('First match'), findsWidgets);
  });

  testWidgets('an open request for a tournament that is gone changes nothing', (
    tester,
  ) async {
    await tester.runAsync(seedTournament);
    await pumpScreen(tester);

    await tester.runAsync(() async {
      appState.switchToEngineTournament(tournamentId: 'deleted-last-week');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await _settle(tester);

    // A stale request — the tournament was deleted since — leaves the screen
    // exactly as it was and says so, rather than blanking it.
    expect(controller.selected?.id, 'seeded-match');
    expect(find.text('Seeded match'), findsWidgets);
    expect(find.text('Crosstable'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(find.textContaining('deleted-last-week'), findsOneWidget);
  });

  testWidgets('the history rail says how each match ended', (tester) async {
    await tester.runAsync(seedTournament);
    await pumpScreen(tester);

    expect(find.text('History'), findsOneWidget);
    // Runs are grouped by day, and a seeded one was created just now.
    expect(find.text('TODAY'), findsOneWidget);
    // Beta won the only game played, and the rail says so without the
    // tournament having to be opened.
    expect(find.text('Alpha 0\u20131 Beta'), findsOneWidget);
    expect(find.textContaining('1/2 games ·'), findsOneWidget);
  });

  testWidgets('the rail can be filtered once there are enough runs', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (final name in [
        'Alpha trial',
        'Beta trial',
        'Gamma trial',
        'Delta trial',
        'Epsilon trial',
        'Endgame study',
      ]) {
        await seedTournament(name: name);
      }
    });
    await pumpScreen(tester);

    expect(find.text('Alpha trial'), findsWidgets);
    await tester.enterText(find.byType(TextField).first, 'endgame');
    await tester.pump();

    expect(find.text('Endgame study'), findsWidgets);
    expect(find.text('Alpha trial'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'nothing like this');
    await tester.pump();
    expect(find.textContaining('No tournament matches'), findsOneWidget);
  });
}
