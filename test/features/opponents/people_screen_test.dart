import 'package:chess_auto_prep/features/opponents/models/person_record.dart';
import 'package:chess_auto_prep/features/opponents/services/opponent_store.dart';
import 'package:chess_auto_prep/features/opponents/widgets/opponent_actions.dart';
import 'package:chess_auto_prep/features/opponents/widgets/people_screen.dart';
import 'package:chess_auto_prep/features/opponents/widgets/player_table.dart';
import 'package:chess_auto_prep/models/analysis_player_info.dart';
import 'package:chess_auto_prep/services/analysis_games_service.dart';
import 'package:chess_auto_prep/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Games extends AnalysisGamesService {
  @override
  Future<List<AnalysisPlayerInfo>> getAllCachedPlayers() async => [
    const AnalysisPlayerInfo(
      platform: 'chesscom',
      username: 'jane',
      gameCount: 4,
    ),
  ];
}

void main() {
  late OpponentStore store;
  late MemoryOpponentStorage disk;

  setUp(() async {
    disk = MemoryOpponentStorage();
    store = OpponentStore(disk);
    await store.ensureLoaded();
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: PeopleScreen(
          store: store,
          actions: OpponentActions(store: store, games: _Games()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'opens all players with saved accounts and persists identity edits',
    (tester) async {
      await open(tester);
      final jane = store.people.single;
      expect(jane.chesscom, 'jane');
      expect(find.text('Player database'), findsOneWidget);
      expect(find.text('Ready'), findsNothing);
      expect(find.text('Analyze games'), findsOneWidget);
      expect(find.text('Create group'), findsNothing);
      await tester.enterText(
        find.byKey(Key('player-${jane.id}-Name')),
        'Jane Doe',
      );
      await tester.enterText(
        find.byKey(Key('player-${jane.id}-USCF ID')),
        '12345678',
      );
      await tester.pumpAndSettle();
      final reopened = OpponentStore(disk);
      await reopened.ensureLoaded();
      expect(reopened.people.single.name, 'Jane Doe');
      expect(reopened.people.single.uscfId, '12345678');
      expect(reopened.people.single.gameSetKeys, jane.gameSetKeys);
      expect(jane.gameSetKeys, isNotEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saved sources use database navigation without popping the table',
    (tester) async {
      final actions = OpponentActions(store: store, games: _Games());
      await actions.addSavedPlayers();
      AnalysisPlayerInfo? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerTable(
              store: store,
              actions: actions,
              people: store.people,
              onAnalyse: (_) async {},
              onRemove: (_) async {},
              onOpenGames: (info) async => opened = info,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saved sources'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Chess.com: jane · 4 games'));
      await tester.tap(find.text('Chess.com: jane · 4 games'));
      await tester.pumpAndSettle();
      expect(opened?.username, 'jane');
      expect(find.byType(PlayerTable), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('deleting a linked record survives reopening', (tester) async {
    await open(tester);
    await store.deletePerson(store.people.single.id);
    await tester.pumpWidget(const SizedBox());
    store = OpponentStore(disk);
    await store.ensureLoaded();
    await open(tester);
    expect(store.people, isEmpty);
  });

  testWidgets('pasted spreadsheet merges existing IDs without making groups', (
    tester,
  ) async {
    await store.savePerson(
      PersonRecord.create(
        name: 'My chosen name',
        uscfId: '12345678',
        notes: 'Keep this note',
      ),
    );
    await open(tester);
    await tester.tap(find.byKey(const Key('people-paste')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText?.startsWith('Paste a player table') == true,
      ),
      'Name\tUSCF ID\tChess.com\nImported name\t12345678\tnew_handle\nAlex\t87654321\talex',
    );
    await tester.tap(find.text('Preview players'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to database'));
    await tester.pumpAndSettle();
    expect(store.tournaments, isEmpty);
    expect(store.matchPerson(uscfId: '12345678')!.name, 'My chosen name');
    expect(store.matchPerson(uscfId: '12345678')!.notes, 'Keep this note');
    expect(store.matchPerson(uscfId: '12345678')!.chesscom, 'new_handle');
    expect(store.matchPerson(uscfId: '87654321')!.name, 'Alex');
    expect(find.text('Add to database'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
