import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/models/analysis_player_info.dart';
import 'package:chess_auto_prep/screens/player_selection_screen.dart';
import 'package:chess_auto_prep/services/analysis_games_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The picker's job is to make "how do I get a player in here?" answerable
/// without reading anyone's mind. These tests pin what the old five-button
/// layout got wrong: on first run the three ways in are *on the screen*, and
/// once there are players there is exactly **one** add control.

/// Lists players from memory. The real service reads the documents directory,
/// and `testWidgets` runs in a fake-async zone where a `dart:io` read never
/// completes — the screen would sit on its spinner forever.
class _FakeGamesService extends AnalysisGamesService {
  _FakeGamesService(this.players);

  final List<AnalysisPlayerInfo> players;
  final deleted = <String>[];

  @override
  Future<List<AnalysisPlayerInfo>> getAllCachedPlayers() async => players;

  @override
  Future<void> deletePlayerData(String platform, String username) async {
    deleted.add('${platform}_$username');
    players.removeWhere(
      (p) => p.platform == platform && p.username == username,
    );
  }
}

AnalysisPlayerInfo _player({
  required String platform,
  required String username,
  int gameCount = 42,
  int? monthsBack = 6,
}) => AnalysisPlayerInfo(
  platform: platform,
  username: username,
  gameCount: gameCount,
  monthsBack: monthsBack,
  downloadedAt: DateTime.now(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  AnalysisPlayerInfo? picked;

  /// Push the picker from a host page so popping it returns a real value.
  Future<_FakeGamesService> pumpPicker(
    WidgetTester tester,
    List<AnalysisPlayerInfo> players,
  ) async {
    picked = null;
    final service = _FakeGamesService([...players]);

    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>(
        create: (_) => AppState(),
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  picked = await Navigator.of(context).push<AnalysisPlayerInfo>(
                    MaterialPageRoute(
                      builder: (_) =>
                          PlayerSelectionScreen(gamesService: service),
                    ),
                  );
                },
                child: const Text('open picker'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open picker'));
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('first run spells out all three ways to add a player', (
    tester,
  ) async {
    await pumpPicker(tester, const []);

    expect(find.text('No players yet'), findsOneWidget);
    expect(find.text('Download a player’s games…'), findsOneWidget);
    expect(find.text('Open PGN files…'), findsOneWidget);
    expect(find.text('Add a whole tournament field…'), findsOneWidget);
  });

  testWidgets('a saved player is listed with one add control, not three', (
    tester,
  ) async {
    await pumpPicker(tester, [
      _player(platform: 'chesscom', username: 'hikaru'),
    ]);

    expect(find.text('hikaru'), findsOneWidget);
    expect(find.textContaining('42 games · Chess.com'), findsOneWidget);

    // The one add control, and no leftover FAB stack.
    expect(find.byKey(const Key('add-player-button')), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);

    // The three sources live behind it, worded exactly as on first run.
    await tester.tap(find.byKey(const Key('add-player-button')));
    await tester.pumpAndSettle();
    expect(find.text('Download a player’s games…'), findsOneWidget);
    expect(find.text('Open PGN files…'), findsOneWidget);
    expect(find.text('Add a whole tournament field…'), findsOneWidget);
  });

  testWidgets('tapping a player pops the screen with it', (tester) async {
    await pumpPicker(tester, [
      _player(platform: 'lichess', username: 'penguingm1'),
    ]);

    await tester.tap(find.text('penguingm1'));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerSelectionScreen), findsNothing);
    expect(picked?.username, 'penguingm1');
    expect(picked?.platform, 'lichess');
  });

  testWidgets('a PGN import is not offered a download it cannot perform', (
    tester,
  ) async {
    await pumpPicker(tester, [
      _player(platform: 'import', username: 'my pgn file', monthsBack: null),
    ]);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();

    expect(find.text('Remove from this list'), findsOneWidget);
    expect(find.text('Download the latest games'), findsNothing);
    expect(find.text('Download a different range…'), findsNothing);
  });

  testWidgets('removing a player asks first, then drops it from the list', (
    tester,
  ) async {
    final service = await pumpPicker(tester, [
      _player(platform: 'chesscom', username: 'hikaru'),
    ]);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from this list'));
    await tester.pumpAndSettle();

    expect(find.text('Remove hikaru?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(service.deleted, ['chesscom_hikaru']);
    expect(find.text('hikaru'), findsNothing);
    expect(find.text('No players yet'), findsOneWidget);
  });
}
