// The Players dialogs: removing a person (and what goes with them), adding
// or editing one, and pasting several. (Imported metadata and a legacy
// alias kept through an edit are in shell_players_test.dart.)
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/features/players/player_dialogs.dart';
import 'package:chess_auto_prep/features/players/players.dart';
import 'package:chess_auto_prep/features/players/saved_games.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The directory in memory, whose saves can be made to fail.
final class _Store implements PlayerStore {
  final inner = MemoryPlayers();
  Object? failSaves;
  @override
  Future<PlayerDirectory> read() => inner.read();
  @override
  Future<void> savePlayer(Player player, {Player? expected}) async {
    if (failSaves case final thrown?) throw thrown;
    await inner.savePlayer(player, expected: expected);
  }

  @override
  Future<void> saveGroup(PlayerGroup group, {PlayerGroup? expected}) =>
      inner.saveGroup(group, expected: expected);
  @override
  Future<void> removePlayer(Player player) => inner.removePlayer(player);
  @override
  Future<void> removeGroup(PlayerGroup group) => inner.removeGroup(group);
}

GamesSummary _summary({
  int downloaded = 0,
  int keptGames = 0,
  bool keptKnown = true,
  List<KeptDownload> kept = const [],
}) => (
  downloaded: downloaded,
  linked: 0,
  fetched: null,
  kept: kept,
  keptGames: keptGames,
  keptKnown: keptKnown,
);

void main() {
  late _Store store;
  late Players owner;
  setUp(() {
    store = _Store();
    owner = Players(store, PendingWrites());
  });
  tearDown(() => owner.dispose());

  Object? answer;
  var answered = false;

  /// Opens the dialog [open] shows from a button, keeping what it answers.
  Future<void> show(
    WidgetTester tester,
    Future<Object?> Function(BuildContext context) open,
  ) async {
    answer = null;
    answered = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                answer = await open(context);
                answered = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  /// Presses [label] and lets the save it starts finish.
  Future<void> commit(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  group('Remove player', () {
    final alex = Player.create('Alex');

    testWidgets('while games are counted, or with none to delete, offers '
        'only to remove', (tester) async {
      for (final saved in [null, _summary(downloaded: 4, keptGames: 4)]) {
        await show(tester, (c) => removePlayer(c, alex, saved: saved));
        expect(find.text('Remove “Alex”?'), findsOneWidget);
        expect(find.text('Saved games and studies stay on disk.'), findsOne);
        expect(find.text('Remove and delete games'), findsNothing);
        await press(tester, 'Remove');
        expect(answer, Removal.keepGames);
      }
    });

    testWidgets('with the user\'s accounts unreadable, says downloads cannot '
        'be deleted', (tester) async {
      await show(
        tester,
        (c) => removePlayer(
          c,
          alex,
          saved: _summary(downloaded: 4, keptKnown: false),
        ),
      );
      expect(
        find.text(
          'Saved games and studies stay on disk. Downloads can’t be deleted '
          'while your accounts can’t be read.',
        ),
        findsOneWidget,
      );
      expect(find.text('Remove and delete games'), findsNothing);
      await press(tester, 'Cancel');
      expect(answered, isTrue);
      expect(answer, isNull);
    });

    testWidgets('with downloads to delete, offers to delete them too, and '
        'says what stays', (tester) async {
      await show(
        tester,
        (c) => removePlayer(
          c,
          alex,
          saved: _summary(
            downloaded: 5,
            keptGames: 2,
            kept: [
              (site: GameSite.lichess, username: 'alex', otherPerson: null),
            ],
          ),
        ),
      );
      expect(
        find.text(
          'Linked studies stay on disk. Their 3 downloaded games can go to '
          'the recovery folder too. Keeps Lichess alex (your account).',
        ),
        findsOneWidget,
      );
      await press(tester, 'Remove and delete games');
      expect(answer, Removal.withGames);

      await show(
        tester,
        (c) => removePlayer(c, alex, saved: _summary(downloaded: 1)),
      );
      expect(
        find.text(
          'Linked studies stay on disk. Their 1 downloaded game can go to '
          'the recovery folder too.',
        ),
        findsOneWidget,
      );
      expect(find.text('Remove and delete games'), findsOneWidget);
      await press(tester, 'Remove, keep games');
      expect(answer, Removal.keepGames);
    });
  });

  test('what a delete keeps is said in one sentence', () {
    const lichess = (
      site: GameSite.lichess,
      username: 'alex',
      otherPerson: null,
    );
    const chesscom = (
      site: GameSite.chesscom,
      username: 'bob',
      otherPerson: 'Carol',
    );
    const third = (site: GameSite.lichess, username: 'cy', otherPerson: 'Di');
    expect(keptLine([chesscom]), 'Keeps Chess.com bob (also Carol’s).');
    expect(
      keptLine([lichess, chesscom]),
      'Keeps Lichess alex (your account) and Chess.com bob (also Carol’s).',
    );
    expect(
      keptLine([lichess, chesscom, third]),
      'Keeps Lichess alex (your account), Chess.com bob (also Carol’s) and '
      'Lichess cy (also Di’s).',
    );
  });

  group('Add or edit player', () {
    Finder box(String label) => find.widgetWithText(TextFormField, label);

    testWidgets('a new player is saved with every field read as its kind', (
      tester,
    ) async {
      await show(tester, (c) => editPlayer(c, owner));
      expect(find.text('Add player'), findsOneWidget);
      await tester.enterText(box('Name'), 'Alex Kim');
      await tester.enterText(box('Lichess usernames'), 'alexk, alex2');
      await tester.enterText(box('Names used in PGN files'), ' Kim, A ; ;A.K.');
      await tester.enterText(box('US Chess ID'), '12345678');
      await tester.enterText(box('Rating'), '1850');
      await tester.enterText(box('Prep notes'), '  Plays the French  ');
      await commit(tester, 'Save player');
      expect(answered, isTrue);
      final saved = store.inner.players.values.single;
      expect(answer, isA<Player>());
      expect((answer! as Player).id, saved.id);
      expect(saved.name, 'Alex Kim');
      expect(saved.fields['pgn_files'], isEmpty);
      expect(saved.fields['aliases'], ['Kim, A', 'A.K.']);
      expect(saved.fields['uscf_id'], '12345678');
      expect(saved.fields['rating'], 1850);
      expect(saved.fields['fide_id'], isNull);
      expect(saved.fields['notes'], 'Plays the French');
      expect(saved.accounts.map((a) => a.username), ['alexk', 'alex2']);
    });

    testWidgets('a player needs a name, numbers in digits and usernames not '
        'links', (tester) async {
      await show(tester, (c) => editPlayer(c, owner));
      await press(tester, 'Save player');
      expect(find.text('Enter a player name.'), findsOneWidget);
      await tester.enterText(box('Name'), 'Alex');
      for (final label in ['US Chess ID', 'FIDE ID', 'Rating']) {
        await tester.enterText(box(label), '12a');
        await press(tester, 'Save player');
        expect(find.text('Use digits only.'), findsOneWidget, reason: label);
        await tester.enterText(box(label), '');
      }
      for (final label in ['Chess.com usernames', 'Lichess usernames']) {
        await tester.enterText(box(label), 'https://lichess.org/@/alex');
        await press(tester, 'Save player');
        expect(
          find.text('Enter usernames, not profile URLs.'),
          findsOneWidget,
          reason: label,
        );
        await tester.enterText(box(label), 'alex_k-1, bob');
      }
      await tester.enterText(box('Names used in PGN files'), 'https://x');
      await commit(tester, 'Save player');
      expect(answered, isTrue);
      expect(store.inner.players, hasLength(1));
    });

    testWidgets('an edit writes the fields changed and drops a PGN file '
        'taken off, keeping links it cannot read', (tester) async {
      final alex = Player.create('Alex').edited({
        'uscf_id': 12345678,
        'notes': 'old',
        'pgn_files': ['/games/a.pgn', '/games/b.pgn', 7],
        'aliases': ['A.', 3],
      });
      await tester.runAsync(() => owner.save(alex));
      final held = owner.players.single;
      await show(tester, (c) => editPlayer(c, owner, player: held));
      expect(find.text('Edit Alex'), findsOneWidget);
      expect(find.text('a.pgn'), findsOneWidget);
      tester
          .widget<InputChip>(find.widgetWithText(InputChip, 'b.pgn'))
          .onDeleted!();
      await tester.pump();
      expect(find.text('b.pgn'), findsNothing);
      await tester.enterText(box('Names used in PGN files'), 'A.; Al');
      await commit(tester, 'Save player');
      final saved = store.inner.players.values.single;
      expect(saved.fields['pgn_files'], ['/games/a.pgn', 7]);
      expect(saved.fields['aliases'], ['A.', 'Al', 3]);
      expect(saved.fields['uscf_id'], 12345678);
      expect(saved.fields['notes'], 'old');
    });

    testWidgets('an edit leaving the files as they were writes them as they '
        'were', (tester) async {
      final alex = Player.create('Alex').edited({
        'pgn_files': ['/games/a.pgn', 7],
        'aliases': {'odd': true},
      });
      await tester.runAsync(() => owner.save(alex));
      final held = owner.players.single;
      await show(tester, (c) => editPlayer(c, owner, player: held));
      await tester.enterText(box('Names used in PGN files'), 'Al');
      await commit(tester, 'Save player');
      final saved = store.inner.players.values.single;
      expect(saved.fields['pgn_files'], ['/games/a.pgn', 7]);
      expect(saved.fields['aliases'], [
        'Al',
        {'odd': true},
      ]);
    });

    testWidgets('a save that fails stays open and says why', (tester) async {
      store.failSaves = StateError('disk');
      await show(tester, (c) => editPlayer(c, owner));
      await tester.enterText(box('Name'), 'Alex');
      await commit(tester, 'Save player');
      expect(answered, isFalse);
      expect(find.text('Could not save.'), findsOneWidget);
      expect(find.text('Add player'), findsOneWidget);
    });
  });

  group('Paste players', () {
    const table = 'Name,Lichess\nAlex Kim,alexk\nBea Lu,';

    testWidgets('previews the players read, then adds them', (tester) async {
      await show(tester, (c) => importPlayers(c, owner));
      await tester.enterText(find.byType(TextField), table);
      await press(tester, 'Preview players');
      expect(
        find.text(
          '2 players · people already listed keep their notes and filled '
          'fields',
        ),
        findsOneWidget,
      );
      expect(find.text('Lichess alexk'), findsOneWidget);
      expect(find.text('No online accounts'), findsOneWidget);
      await commit(tester, 'Add players');
      expect(answered, isTrue);
      expect(store.inner.players.values.map((p) => p.name).toSet(), {
        'Alex Kim',
        'Bea Lu',
      });
    });

    testWidgets('a change to the text asks for a new preview', (tester) async {
      await show(tester, (c) => importPlayers(c, owner));
      await tester.enterText(find.byType(TextField), 'Name\nAlex');
      await press(tester, 'Preview players');
      expect(find.textContaining('1 player ·'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Name\nAlex\nBea');
      await tester.pump();
      expect(find.textContaining('1 player ·'), findsNothing);
      expect(find.text('Preview players'), findsOneWidget);
    });

    testWidgets('nothing to read says so', (tester) async {
      await show(tester, (c) => importPlayers(c, owner));
      await tester.enterText(find.byType(TextField), '[]');
      await press(tester, 'Preview players');
      expect(find.text('No players found.'), findsOneWidget);
      expect(find.text('Add players'), findsNothing);
    });

    testWidgets('in a group, adds to it', (tester) async {
      final club = PlayerGroup.create('Club');
      await tester.runAsync(() => owner.saveGroup(club));
      owner.showGroup(club.id);
      await show(tester, (c) => importPlayers(c, owner));
      await tester.enterText(find.byType(TextField), 'Name\nAlex');
      await press(tester, 'Preview players');
      await commit(tester, 'Add to group');
      final alex = store.inner.players.values.single;
      expect(store.inner.groups[club.id]!.contains(alex.id), isTrue);
    });

    testWidgets('players that cannot be saved stay in the dialog, which says '
        'why', (tester) async {
      store.failSaves = StateError('disk');
      await show(tester, (c) => importPlayers(c, owner));
      await tester.enterText(find.byType(TextField), 'Name\nAlex');
      await press(tester, 'Preview players');
      await commit(tester, 'Add players');
      expect(answered, isFalse);
      expect(find.text('Could not save.'), findsOneWidget);
    });
  });
}
