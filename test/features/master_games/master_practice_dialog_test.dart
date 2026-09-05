@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/games/models/recent_game.dart';
import 'package:chess_auto_prep/features/master_games/controllers/master_practice_controller.dart';
import 'package:chess_auto_prep/features/master_games/services/master_practice_review.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/features/master_games/widgets/master_practice_dialog.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:chess_auto_prep/services/master_games/master_games_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'master_practice_fixtures.dart';

/// The real controller minus the file write, which is real IO a widget test
/// cannot wait on; the write itself is covered by the controller test.
class _NoWriteController extends MasterPracticeController {
  _NoWriteController({required super.service});

  final List<MasterGame> written = [];

  @override
  Future<({String path, int index})> writeKeyGames(
    MasterPracticeEntry entry, {
    required MasterGame focus,
  }) async {
    written.add(focus);
    return (path: '/tmp/master-practice.pgn', index: 0);
  }
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  late Directory tmp;
  late MasterGamesService service;
  late _NoWriteController controller;
  late AppState appState;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('master_practice_ui');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    final dbPath = '${tmp.path}/master_games.db';
    importPgnIntoMasterGames(
      MasterGamesImportRequest(
        dbPath: dbPath,
        pgnText: masterPgn,
        twicIssue: 1660,
      ),
    );
    service = MasterGamesService(dbPathProvider: () async => dbPath);
    await service.load();
    controller = _NoWriteController(service: service);
    appState = AppState();
  });

  tearDown(() async {
    service.dispose();
    await tmp.delete(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester, {
    List<RecentGame>? games,
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showMasterPracticeReview(
                  context,
                  appState: appState,
                  games: games ?? myGames(),
                  windowLabel: 'last 7 games',
                  controller: controller,
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
  }

  testWidgets('sections say who left first, and the header counts it', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('You left master practice first (2)'), findsOneWidget);
    expect(find.text('Your opponents left first (1)'), findsOneWidget);
    expect(find.text('Stayed in master practice (2)'), findsOneWidget);
    final headline = tester.widget<Text>(
      find.byKey(const Key('master-practice-headline')),
    );
    expect(headline.data, contains('you left master practice first in 3'));
    expect(find.textContaining('1 game skipped'), findsOneWidget);
  });

  testWidgets('the repeated branch point is first, and shows its count', (
    tester,
  ) async {
    await pump(tester);
    // Two rows read "6. Bc4" — mine (twice) and my opponent's (once).
    expect(find.text('6. Bc4'), findsNWidgets(2));
    expect(find.text('2×'), findsOneWidget);
    expect(find.textContaining('Masters play Be3, Bg5'), findsNWidgets(2));
    expect(find.text('1. b4'), findsOneWidget);
  });

  testWidgets(
    'the detail pane puts the move, the alternatives and the games together',
    (tester) async {
      await pump(tester);
      expect(find.text('You played 6. Bc4'), findsOneWidget);
      expect(
        find.textContaining('3 master games reach this position'),
        findsOneWidget,
      );
      expect(find.text('Masters play here'), findsOneWidget);
      expect(find.text('Be3'), findsOneWidget);
      expect(find.text('2 games'), findsOneWidget);
      expect(find.text('75%'), findsOneWidget);
      expect(find.text('Games to open'), findsOneWidget);
      expect(find.text('Carlsen – Nakamura'), findsOneWidget);
      expect(find.text('Your games'), findsOneWidget);
      expect(find.textContaining('vs bob · won'), findsOneWidget);
      expect(find.textContaining('vs dan · drew'), findsOneWidget);
    },
  );

  testWidgets('selecting the opponent\'s copy reads from my side', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.textContaining('vs carl'));
    await tester.pumpAndSettle();
    expect(find.text('Your opponent played 6. Bc4'), findsOneWidget);
  });

  testWidgets('a game that outran the corpus explains, and offers its line', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.textContaining('vs eve'));
    await tester.pumpAndSettle();
    expect(find.text('In master practice through 7... Be6'), findsOneWidget);
    expect(find.textContaining('No master game continued'), findsOneWidget);
    expect(find.text('Masters play here'), findsNothing);
    expect(find.text('Carlsen – Nakamura'), findsOneWidget);
  });

  testWidgets('opening a master game hands the viewer the file at the branch', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Carlsen – Nakamura'));
    await tester.pumpAndSettle();
    expect(find.text('Your games vs. master practice'), findsNothing);
    expect(controller.written.single.white, 'Carlsen,Magnus');
    final handoff = appState.takeHandoff<OpenPgnViewer>()!;
    expect(handoff.pgnPath, '/tmp/master-practice.pgn');
    expect(handoff.gameIndex, 0);
    expect(handoff.ply, 11);
  });

  testWidgets('opening my own game lands just after the move in question', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.textContaining('vs bob · won'));
    await tester.pumpAndSettle();
    final handoff = appState.takeHandoff<OpenPgnViewer>()!;
    expect(handoff.pgnPath, '/tmp/lichess_me.pgn');
    expect(handoff.gameId, 'a');
    expect(handoff.ply, 11);
  });

  testWidgets('with no games it says so instead of an empty list', (
    tester,
  ) async {
    await pump(tester, games: const []);
    expect(
      find.textContaining('No games in your last 7 games'),
      findsOneWidget,
    );
  });

  testWidgets('it lays out in a small window without overflowing', (
    tester,
  ) async {
    await pump(tester, size: const Size(900, 600));
    expect(tester.takeException(), isNull);
    expect(find.text('You played 6. Bc4'), findsOneWidget);
  });
}
