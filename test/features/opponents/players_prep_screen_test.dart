import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/opponents/models/person_record.dart';
import 'package:chess_auto_prep/features/opponents/models/tournament.dart';
import 'package:chess_auto_prep/features/opponents/services/opponent_store.dart';
import 'package:chess_auto_prep/features/opponents/widgets/opponent_actions.dart';
import 'package:chess_auto_prep/features/opponents/widgets/players_prep_screen.dart';
import 'package:chess_auto_prep/features/opponents/widgets/player_table.dart';
import 'package:chess_auto_prep/models/analysis_player_info.dart';
import 'package:chess_auto_prep/services/analysis_games_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Games extends AnalysisGamesService {
  int reads = 0;
  @override
  Future<List<AnalysisPlayerInfo>> getAllCachedPlayers() async {
    reads++;
    return [];
  }
}

class _Actions extends OpponentActions {
  _Actions(OpponentStore store, _Games games)
    : super(store: store, games: games);
  @override
  Future<AnalysisPlayerInfo?> ensureGames(
    BuildContext context,
    PersonRecord person, {
    String? group,
  }) async => person.toPlayerInfo(group: group);
}

void main() {
  late OpponentStore store;
  late AppState app;
  late PersonRecord jane;
  late Tournament group;
  late _Games games;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = OpponentStore(MemoryOpponentStorage());
    await store.ensureLoaded();
    await store.markSavedAccountsImported();
    jane = await store.savePerson(
      PersonRecord.create(name: 'Jane Doe', lichess: 'janed'),
    );
    group = await store.createTournament('Club championship');
    await store.saveTournament(
      group.withEntry(TournamentEntry(personId: jane.id)),
    );
    app = AppState()..setMode(AppMode.playersPrep);
    games = _Games();
  });

  tearDown(() {
    app.dispose();
    store.dispose();
  });

  Future<void> show(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: PlayersPrepScreen(
            store: store,
            actions: _Actions(store, games),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openGroup(WidgetTester tester) async {
    await tester.tap(find.text('Groups (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('tournament-${group.id}')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'directory and groups are reachable without choosing analysis material',
    (tester) async {
      await show(tester);
      expect(find.byKey(const Key('people-add')), findsOneWidget);
      expect(app.currentMode, AppMode.playersPrep);
      await openGroup(tester);
      expect(find.text('Groups / Club championship'), findsOneWidget);
      expect(find.byKey(Key('prepare-${jane.id}')), findsOneWidget);
      expect(app.hasPending<OpenPlayerAnalysis>(), isFalse);
      await tester.tap(find.byKey(const Key('prep-back-to-groups')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tournaments-new')), findsOneWidget);
    },
  );

  testWidgets(
    'group analysis hands off the chosen person and preserves the sheet',
    (tester) async {
      await show(tester);
      await openGroup(tester);
      await tester.tap(find.byKey(Key('prepare-${jane.id}')));
      await tester.pumpAndSettle();
      expect(app.currentMode, AppMode.positionAnalysis);
      expect(
        app.takeHandoff<OpenPlayerAnalysis>()?.player.displayName,
        'Jane Doe',
      );
      final before = games.reads;
      app.setMode(AppMode.playersPrep);
      await tester.pumpAndSettle();
      expect(find.text('Groups / Club championship'), findsOneWidget);
      expect(games.reads, greaterThan(before));
      await tester.tap(find.text('All players (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Groups (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Groups / Club championship'), findsOneWidget);
    },
  );

  testWidgets('the directory also hands analysis to the canonical mode', (
    tester,
  ) async {
    await show(tester);
    final table = tester.widget<PlayerTable>(find.byType(PlayerTable));
    await table.onAnalyse(jane);
    await tester.pumpAndSettle();
    expect(app.currentMode, AppMode.positionAnalysis);
    final player = app.takeHandoff<OpenPlayerAnalysis>()!.player;
    expect(player.displayName, 'Jane Doe');
    expect(player.accounts.single.username, 'janed');
  });

  testWidgets('create a group, include a saved person and search the catalog', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.text('Groups (1)'));
    await tester.pumpAndSettle();
    final name = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'New group',
    );
    await tester.enterText(name, 'Weekend practice');
    await tester.tap(find.byKey(const Key('tournaments-new')));
    await tester.pumpAndSettle();
    expect(find.text('Groups / Weekend practice'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tournament-add-opponent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('add-opponent-${jane.id}')));
    await tester.pumpAndSettle();
    expect(
      store.tournamentNamed('Weekend practice')!.contains(jane.id),
      isTrue,
    );
    await tester.tap(find.byKey(const Key('prep-back-to-groups')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Search groups',
      ),
      'Weekend',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(Key('tournament-${group.id}')), findsNothing);
    expect(find.text('Open group'), findsOneWidget);
  });
}
