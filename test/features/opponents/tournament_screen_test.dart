import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/opponents/models/person_record.dart';
import 'package:chess_auto_prep/features/opponents/models/tournament.dart';
import 'package:chess_auto_prep/features/opponents/widgets/opponent_actions.dart';
import 'package:chess_auto_prep/features/opponents/services/opponent_store.dart';
import 'package:chess_auto_prep/features/opponents/widgets/tournament_screen.dart';
import 'package:chess_auto_prep/features/opponents/widgets/tournaments_screen.dart';
import 'package:chess_auto_prep/models/analysis_player_info.dart';
import 'package:chess_auto_prep/services/analysis_games_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The sheet is the spreadsheet it replaces: every column visible, a tick
/// per row, and the row itself is the way into Player Analysis.
class _FakeGamesService extends AnalysisGamesService {
  _FakeGamesService(this.players);
  final List<AnalysisPlayerInfo> players;

  @override
  Future<List<AnalysisPlayerInfo>> getAllCachedPlayers() async => players;

  @override
  Future<AnalysisPlayerInfo?> findExistingPlayer(
    String platform,
    String username,
  ) async {
    for (final p in players) {
      if (p.platform == platform &&
          p.username.toLowerCase() == username.toLowerCase()) {
        return p;
      }
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late OpponentStore store;
  late PersonRecord jane;
  late PersonRecord bob;
  late PersonRecord carol;
  late Tournament open;
  late _FakeGamesService games;

  setUp(() async {
    store = OpponentStore(MemoryOpponentStorage());
    await store.ensureLoaded();
    jane = await store.savePerson(
      PersonRecord.create(
        name: 'Jane Doe',
        uscfId: '12345678',
        chesscom: 'janed',
        rating: 1850,
        notes: 'Plays the London.',
      ),
    );
    bob = await store.savePerson(
      PersonRecord.create(name: 'Bob Roe', lichess: 'bobr'),
    );
    carol = await store.savePerson(PersonRecord.create(name: 'Carol Poe'));
    open = await store.saveTournament(
      (await store.createTournament('Spring Open 2026', date: '2026-04-12'))
          .withEntry(
            TournamentEntry(
              personId: jane.id,
              rating: 1850,
              pairingProb: 0.42,
              likelyRound: 2,
            ),
          )
          .withEntry(TournamentEntry(personId: bob.id, rating: 1700)),
    );
    games = _FakeGamesService([
      jane.toPlayerInfo(group: 'Spring Open 2026').copyWith(gameCount: 120),
    ]);
  });

  AnalysisPlayerInfo? picked;

  Future<void> pumpSheet(WidgetTester tester) async {
    picked = null;
    tester.view.physicalSize = const Size(1300, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final actions = OpponentActions(store: store, games: games);
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
                      builder: (_) => TournamentScreen(
                        tournamentId: open.id,
                        store: store,
                        actions: actions,
                      ),
                    ),
                  );
                },
                child: const Text('open sheet'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
  }

  test('the fake game-set is keyed by the person\'s player name', () async {
    final actions = OpponentActions(store: store, games: games);
    final sets = await actions.gameSetsByUsername();
    expect(sets.keys, [jane.playerName.toLowerCase()]);
    expect(actions.gameSetFor(sets, jane)?.gameCount, 120);
  });

  test(
    'saved accounts become reusable people and matching respects platform',
    () async {
      final disk = MemoryOpponentStorage();
      final directory = OpponentStore(disk);
      final source = _FakeGamesService([
        const AnalysisPlayerInfo(
          platform: 'chesscom',
          username: 'shared',
          gameCount: 8,
        ),
        const AnalysisPlayerInfo(
          platform: 'lichess',
          username: 'shared',
          gameCount: 5,
        ),
      ]);
      final actions = OpponentActions(store: directory, games: source);
      expect(await actions.addSavedPlayers(), 2);
      expect(await actions.addSavedPlayers(), 0);
      expect(directory.people.length, 2);
      final chesscom = directory.matchPerson(chesscom: 'shared')!;
      expect(
        actions.gameSetsFor(source.players, chesscom).single.platform,
        'chesscom',
      );
      final reopened = OpponentStore(disk);
      await reopened.ensureLoaded();
      expect(reopened.personForPlayer(source.players.first)?.id, chesscom.id);
    },
  );

  testWidgets('shows every column of the sheet', (tester) async {
    await pumpSheet(tester);
    for (final header in [
      'Name',
      'Rating',
      'USCF ID',
      'Chess.com accounts',
      'Lichess accounts',
      'Reference studies',
      'Games',
      'Notes',
    ]) {
      expect(find.text(header), findsWidgets, reason: header);
    }
    expect(find.text('Spring Open 2026'), findsOneWidget);
    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.text('12345678'), findsOneWidget);
    expect(find.text('janed'), findsOneWidget);
    expect(find.text('Plays the London.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    printOnFailure(
      tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join(' | '),
    );
    expect(find.text('120 saved'), findsOneWidget, reason: 'saved games count');
    expect(find.text('Bob Roe'), findsOneWidget);
    expect(find.text('bobr'), findsOneWidget);
    expect(
      find.text('No saved games'),
      findsOneWidget,
      reason: 'Bob has no games saved',
    );
    expect(find.byIcon(Icons.more_vert), findsNothing);
  });

  testWidgets(
    'editing cells persists identity, multiple accounts and notes without a dialog',
    (tester) async {
      await pumpSheet(tester);
      await tester.enterText(
        find.byKey(Key('player-${jane.id}-Name')),
        'Jane Smith',
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(Key('player-${jane.id}-Chess.com')),
        'janed, jane_alt',
      );
      await tester.pumpAndSettle();
      expect(store.person(jane.id)!.accounts.length, 2);
      expect(store.person(jane.id)!.name, 'Jane Smith');
      expect(
        store.person(jane.id)!.gameSetKeys,
        contains(games.players.single.playerKey),
      );
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byKey(Key('prepare-${jane.id}')));
      await tester.pumpAndSettle();
      expect(picked!.playerKey, games.players.single.playerKey);
    },
  );

  testWidgets('ticking prepared is saved on the tournament', (tester) async {
    await pumpSheet(tester);
    await tester.tap(find.byKey(Key('opponent-prepared-${jane.id}')));
    await tester.pumpAndSettle();
    expect(store.tournament(open.id)!.entries.first.prepared, isTrue);
  });

  testWidgets('tapping a row with games saved pops with that game-set', (
    tester,
  ) async {
    await pumpSheet(tester);
    await tester.tap(find.byKey(Key('prepare-${jane.id}')));
    await tester.pumpAndSettle();
    expect(picked, isNotNull);
    expect(picked!.displayName, 'Jane Doe');
    expect(picked!.group, 'Spring Open 2026');
    expect(find.byType(TournamentScreen), findsNothing);
  });

  testWidgets('add opponent offers people not yet in the field', (
    tester,
  ) async {
    await pumpSheet(tester);
    await tester.tap(find.byKey(const Key('tournament-add-opponent')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('add-opponent-${carol.id}')), findsOneWidget);
    expect(find.byKey(Key('add-opponent-${jane.id}')), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.byKey(Key('add-opponent-${carol.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Carol Poe'), findsOneWidget);
    expect(store.tournament(open.id)!.entries.length, 3);
  });

  testWidgets('a row can be removed from the field, keeping the person', (
    tester,
  ) async {
    await pumpSheet(tester);
    await tester.ensureVisible(find.byTooltip('Remove from group').last);
    await tester.tap(find.byTooltip('Remove from group').last);
    await tester.pumpAndSettle();
    expect(store.tournament(open.id)!.entries.length, 1);
    expect(store.person(bob.id), isNotNull);
    expect(find.text('Bob Roe'), findsNothing);
  });

  testWidgets('the tournaments list opens a sheet and forwards its pick', (
    tester,
  ) async {
    picked = null;
    tester.view.physicalSize = const Size(1300, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final actions = OpponentActions(store: store, games: games);
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
                          TournamentsScreen(store: store, actions: actions),
                    ),
                  );
                },
                child: const Text('open list'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open list'));
    await tester.pumpAndSettle();
    expect(find.text('Groups'), findsOneWidget);
    expect(find.textContaining('2 players'), findsOneWidget);
    await tester.tap(find.byKey(Key('tournament-${open.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('prepare-${jane.id}')));
    await tester.pumpAndSettle();
    expect(picked?.displayName, 'Jane Doe');
    expect(find.byType(TournamentsScreen), findsNothing);
  });
}
