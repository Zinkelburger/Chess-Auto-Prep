// The account research folded under a person's row: what it says closed and
// open, and that Use account links the account beside the ones the person
// has, records who confirmed it, and offers it no more.
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/features/players/player_lookup.dart';
import 'package:chess_auto_prep/features/players/players.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MemoryPlayers store;
  late Players owner;

  setUp(() {
    store = MemoryPlayers();
    owner = Players(store, PendingWrites());
  });
  tearDown(() => owner.dispose());

  Future<Player> saved(WidgetTester tester, Player player) async {
    await tester.runAsync(() async {
      await owner.save(player);
    });
    return owner.players.single;
  }

  Future<void> show(WidgetTester tester, Player player) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: PlayerLookup(player: player, owner: owner),
        ),
      ),
    );
  }

  const research = {
    'status': 'needs_review',
    'candidates': [
      {'site': 'lichess', 'username': 'alexk', 'evidence': 'Same club'},
      {'site': 'chesscom', 'username': 'alex_k'},
      {'site': 'icc', 'username': 'alexk'},
      {'site': 'lichess', 'username': 7},
    ],
    'next_steps': ['Ask at the club'],
  };

  testWidgets('a person with no research shows nothing', (tester) async {
    await show(tester, Player.create('Alex'));
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('research with nothing to open is one quiet line', (
    tester,
  ) async {
    await show(
      tester,
      Player.create('Alex').edited({
        'lookup': {'status': 'not_found'},
      }),
    );
    expect(find.text('Account lookup · not found'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    await show(
      tester,
      Player.create('Alex').edited({'lookup': <String, Object?>{}}),
    );
    expect(find.text('Account lookup · saved research'), findsOneWidget);
  });

  testWidgets('suggested accounts are counted closed and listed open, each '
      'with its evidence', (tester) async {
    await show(tester, Player.create('Alex').edited({'lookup': research}));
    expect(find.text('4 suggested accounts'), findsOneWidget);
    expect(find.text('needs review'), findsOneWidget);
    expect(find.text('Lichess alexk'), findsNothing);
    await tester.tap(find.text('4 suggested accounts'));
    await tester.pump();
    expect(find.text('Lichess alexk'), findsOneWidget);
    expect(find.text('Same club'), findsOneWidget);
    expect(find.text('Chess.com alex_k'), findsOneWidget);
    expect(find.text('icc alexk'), findsOneWidget);
    expect(find.text('No evidence saved.'), findsNWidgets(3));
    expect(find.text('Ask at the club'), findsOneWidget);
    // An account on a site the app does not know, or with no name, cannot
    // be linked.
    final buttons = tester
        .widgetList<TextButton>(find.widgetWithText(TextButton, 'Use account'))
        .toList();
    expect(
      [for (final b in buttons) b.onPressed != null],
      [true, true, false, false],
    );
    await tester.tap(find.text('4 suggested accounts'));
    await tester.pump();
    expect(find.text('Lichess alexk'), findsNothing);
  });

  testWidgets('one suggested account is said in the singular', (tester) async {
    await show(
      tester,
      Player.create('Alex').edited({
        'lookup': {
          'candidates': [
            {'site': 'lichess', 'username': 'alexk'},
          ],
        },
      }),
    );
    expect(find.text('1 suggested account'), findsOneWidget);
  });

  testWidgets('Use account links it beside the person\'s other accounts '
      'there, and records it confirmed by the user', (tester) async {
    final person = await saved(
      tester,
      Player.create('Alex').edited({
        'lichess': 'old',
        'chesscom': 'keep',
        'lookup': {...research, 'confirmed': 'earlier'},
      }),
    );
    await show(tester, person);
    await tester.tap(find.text('4 suggested accounts'));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, 'Use account').first);
      await owner.pending.settle();
    });
    final now = store.players.values.single;
    expect(now.text('lichess'), 'old, alexk');
    expect(now.text('chesscom'), 'keep');
    final lookup = now.fields['lookup']! as Map;
    expect(lookup['status'], 'account');
    expect(lookup['next_steps'], ['Ask at the club']);
    expect(lookup['confirmed'], [
      'earlier',
      {
        'site': 'lichess',
        'username': 'alexk',
        'evidence': 'Same club',
        'confirmed_by': 'user',
      },
    ]);
    expect(lookup['candidates'], [
      for (final c in research['candidates']! as List)
        if ((c as Map)['evidence'] == null) c,
    ]);
  });

  testWidgets('Use account adds a first confirmed account to none', (
    tester,
  ) async {
    final person = await saved(
      tester,
      Player.create('Alex').edited({'lookup': research}),
    );
    await show(tester, person);
    await tester.tap(find.text('4 suggested accounts'));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, 'Use account').at(1));
      await owner.pending.settle();
    });
    final now = store.players.values.single;
    expect(now.text('chesscom'), 'alex_k');
    expect(now.text('lichess'), isEmpty);
    expect((now.fields['lookup']! as Map)['confirmed'], [
      {'site': 'chesscom', 'username': 'alex_k', 'confirmed_by': 'user'},
    ]);
  });

  testWidgets('nothing is linked while the directory is busy', (tester) async {
    owner.busy = true;
    await show(tester, Player.create('Alex').edited({'lookup': research}));
    await tester.tap(find.text('4 suggested accounts'));
    await tester.pump();
    final buttons = tester.widgetList<TextButton>(
      find.widgetWithText(TextButton, 'Use account'),
    );
    expect(buttons.every((b) => b.onPressed == null), isTrue);
    owner.busy = false;
  });
}
