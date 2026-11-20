// One person in Players & prep: who they are and where their games come
// from, the count of their saved games, and what the row and its menu offer
// for the prep and the downloads they have. (Deleting downloads, removing a
// person and the prepared tick are driven in shell_players_test.dart.)
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/features/players/person_row.dart';
import 'package:chess_auto_prep/features/players/saved_games.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/menu_entry.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/window_fixture.dart';

const _oneGame =
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Result "1-0"]\n\n'
    '1. e4 e5 1-0\n';

GamesSummary _summary({int downloaded = 0, int linked = 0, DateTime? at}) => (
  downloaded: downloaded,
  linked: linked,
  fetched: at,
  kept: const [],
  keptGames: 0,
  keptKnown: true,
);

void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  Future<Player> saved(WidgetTester tester, Player player) async {
    await tester.runAsync(() => w.parts.players.directory.save(player));
    return w.parts.players.directory.players.single;
  }

  Future<void> show(WidgetTester tester, Player player) async {
    await tester.binding.setSurfaceSize(const Size(1200, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: PersonRow(
            player: player,
            group: null,
            owner: w.parts.players.directory,
            saved: w.parts.players.saved,
            onAnalyze: (_) {},
            onStudy: (_) {},
            onLink: (_) {},
            onLinkedStudy: (_, _) {},
            onRemove: (_) {},
            onDeleteGames: (_) {},
          ),
        ),
      ),
    );
  }

  /// The entries of the row's `⋯` menu, which is opened and shut again.
  Future<Map<String, VoidCallback?>> menu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Player actions'));
    await tester.pumpAndSettle();
    final entries = {
      for (final entry in tester.widgetList<MenuEntry>(find.byType(MenuEntry)))
        entry.label: entry.run,
    };
    await tester.tap(find.byTooltip('Player actions'));
    await tester.pumpAndSettle();
    return entries;
  }

  testWidgets('says the name and rating, every account by site, the US Chess '
      'ID and the notes', (tester) async {
    await show(
      tester,
      Player.create('Alex Kim').edited({
        'rating': 1850,
        'lichess': 'alexk, alex2',
        'chesscom': 'akim',
        'uscf_id': '12345678',
        'notes': 'Plays the French',
      }),
    );
    expect(find.text('Alex Kim'), findsOneWidget);
    expect(find.text('1850'), findsOneWidget);
    expect(
      find.text('Lichess alexk, alex2 · Chess.com akim · US Chess 12345678'),
      findsOneWidget,
    );
    expect(find.text('Plays the French'), findsOneWidget);
  });

  testWidgets('a person with nothing known says they have no accounts', (
    tester,
  ) async {
    await show(tester, Player.create('Bea'));
    expect(find.text('No online accounts'), findsOneWidget);
    expect(find.textContaining('US Chess'), findsNothing);
  });

  testWidgets('with a prep study, opens it and offers to unlink it; without, '
      'makes one', (tester) async {
    final alex = await saved(tester, Player.create('Alex'));
    await show(tester, alex);
    expect(find.text('New prep study'), findsOneWidget);
    expect((await menu(tester)).keys, isNot(contains('Unlink prep study')));

    final prepared = await saved(
      tester,
      alex.edited({'prep_file': '/studies/Prep – Alex.pgn'}),
    );
    await show(tester, prepared);
    expect(find.text('Open prep study'), findsOneWidget);
    final entries = await menu(tester);
    expect(entries['Unlink prep study'], isNotNull);
    expect(entries['Remove player…'], isNotNull);
  });

  testWidgets('one downloaded game can be deleted, but not while a delete of '
      'them is going', (tester) async {
    const download = DocumentRef('/games_library/lichess_alex.pgn');
    w.store.documents[download] = Opened(_oneGame, scriptedRevision(_oneGame));
    final alex = await saved(
      tester,
      Player.create('Alex').edited({'lichess': 'alex'}),
    );
    final saved_ = w.parts.players.saved;
    await tester.runAsync(saved_.refresh);
    expect(saved_.of(alex)!.deletable, 1);
    await show(tester, alex);
    expect(find.text('1 saved game'), findsOneWidget);
    expect((await menu(tester))['Delete saved games…'], isNotNull);

    saved_.deleting.add(alex.id);
    addTearDown(() => saved_.deleting.remove(alex.id));
    await show(tester, alex);
    final entries = await menu(tester);
    expect(entries.containsKey('Delete saved games…'), isTrue);
    expect(entries['Delete saved games…'], isNull);
  });

  testWidgets('before the games are counted, offers no delete and no count', (
    tester,
  ) async {
    await show(tester, Player.create('Zed').edited({'lichess': 'zed'}));
    expect(find.textContaining('saved game'), findsNothing);
    expect((await menu(tester)).keys, isNot(contains('Delete saved games…')));
  });

  testWidgets('with nothing downloaded, offers no delete', (tester) async {
    final alex = await saved(tester, Player.create('Alex'));
    await tester.runAsync(w.parts.players.saved.refresh);
    await show(tester, alex);
    expect(find.text('No saved games'), findsOneWidget);
    expect((await menu(tester)).keys, isNot(contains('Delete saved games…')));
  });

  test('the saved games line counts games and files, in the singular for '
      'one', () {
    expect(savedLine(null, 2), '');
    expect(savedLine(_summary(), 0), 'No saved games');
    expect(savedLine(_summary(downloaded: 1), 0), '1 saved game');
    expect(
      savedLine(_summary(downloaded: 3, linked: 2), 1),
      '5 saved games · 1 PGN file',
    );
    expect(savedLine(_summary(linked: 4), 2), '4 saved games · 2 PGN files');
    expect(
      savedLine(_summary(downloaded: 2, at: DateTime.now()), 0),
      startsWith('2 saved games · downloaded '),
    );
  });
}
