// Players & prep: switching to the groups and back, a group made, opened,
// added to, taken from and removed — each removal asked first and kept on
// Cancel — the list held while a failed save waits, a single downloaded
// game deleted, and the entries offered only where they can work. (Editing
// people, prepared ticks and deleting with a person are driven in
// shell_players_test.dart.)
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/features/players/players.dart';
import 'package:chess_auto_prep/features/players/players_screen.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:chess_auto_prep/ui/menu_entry.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/window_fixture.dart';

/// The directory in memory, whose next player save can be made to fail.
final class _FlakyPlayers implements PlayerStore {
  final inner = MemoryPlayers();
  Object? throwOnSave;
  @override
  Future<PlayerDirectory> read() => inner.read();
  @override
  Future<void> savePlayer(Player player, {Player? expected}) async {
    if (throwOnSave case final thrown?) {
      throwOnSave = null;
      throw thrown;
    }
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

void main() {
  late _FlakyPlayers store;
  late WindowFixture w;
  final deletes = <Player>[];

  setUp(() {
    deletes.clear();
    store = _FlakyPlayers();
    w = WindowFixture(players: store);
  });
  tearDown(() => w.dispose());

  Players directory() => w.parts.players.directory;

  Future<void> run(WidgetTester tester, Future<void> Function() work) =>
      tester.runAsync(work);

  /// Lets saves and counts that touch real files finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
    }
  }

  Future<void> show(WidgetTester tester, {Players? players}) async {
    tester.view
      ..physicalSize = const Size(1400, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: PlayersScreen(
            players: players ?? directory(),
            saved: w.parts.players.saved,
            onAnalyze: (_) {},
            onDeleteGames: (person, summary) async {
              deletes.add(person);
              return true;
            },
            onStudy: (_) {},
            onLink: (_) {},
            onLinkedStudy: (_, _) {},
            onGroupStudy: (_) {},
            onTrainGroup: (_) {},
            onExport: (_) {},
            onCopy: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The entries of the `⋯` menu named [tooltip], opened and shut again.
  Future<Map<String, VoidCallback?>> menu(
    WidgetTester tester, [
    String tooltip = 'More actions',
  ]) async {
    await tester.tap(find.byTooltip(tooltip));
    await tester.pumpAndSettle();
    final entries = {
      for (final entry in tester.widgetList<MenuEntry>(find.byType(MenuEntry)))
        entry.label: entry.run,
    };
    await tester.tap(find.byTooltip(tooltip));
    await tester.pumpAndSettle();
    return entries;
  }

  Future<void> choose(WidgetTester tester, String tooltip, String entry) async {
    await tester.tap(find.byTooltip(tooltip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(entry));
    await tester.pumpAndSettle();
  }

  testWidgets('Groups lists the groups, narrowed by the search, and one '
      'opens; Back returns to them', (tester) async {
    await show(tester);
    await tester.tap(find.text('Groups'));
    await tester.pumpAndSettle();
    expect(directory().showingGroups, isTrue);
    expect(find.textContaining('No groups yet'), findsOneWidget);

    await run(tester, () async {
      await directory().saveGroup(
        PlayerGroup.create('Club Open').edited({'rounds': 1}),
      );
      await directory().saveGroup(PlayerGroup.create('Spring'));
    });
    await tester.pumpAndSettle();
    expect(find.text('Club Open'), findsOneWidget);
    expect(find.text('1 round · 0 players · 0 prepared'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'zz');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches "zz".'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'club');
    await tester.pumpAndSettle();
    expect(find.text('Spring'), findsNothing);
    await tester.tap(find.text('Club Open'));
    await tester.pumpAndSettle();
    expect(directory().group?.name, 'Club Open');
    expect(find.text('Nobody in this group yet.'), findsOneWidget);
    await tester.tap(find.byTooltip('Back to groups'));
    await tester.pumpAndSettle();
    expect(directory().group, isNull);
    expect(find.text('Spring'), findsOneWidget);

    await tester.tap(find.text('All players'));
    await tester.pumpAndSettle();
    expect(directory().showingGroups, isFalse);
    expect(find.text('No players yet.'), findsOneWidget);
  });

  testWidgets('New group… makes a group and opens it', (tester) async {
    await show(tester);
    await tester.tap(find.text('Groups'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New group…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Group name'),
      'Club Open',
    );
    await tester.tap(find.text('Save group'));
    await settle(tester);
    expect(directory().group?.name, 'Club Open');
    expect(find.text('5 rounds · 0 players · 0 prepared'), findsOneWidget);
  });

  testWidgets('a person is taken from a group only once the question is '
      'answered, and stays in the directory', (tester) async {
    final alex = Player.create('Alex');
    final group = PlayerGroup.create('Club').member(alex.id);
    await run(tester, () async {
      await directory().save(alex);
      await directory().saveGroup(group);
    });
    directory().showGroup(group.id);
    await show(tester);
    await choose(tester, 'Player actions', 'Remove from group…');
    expect(find.text('Remove “Alex” from “Club”?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(directory().group!.contains(alex.id), isTrue);

    await choose(tester, 'Player actions', 'Remove from group…');
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await settle(tester);
    expect(directory().group!.contains(alex.id), isFalse);
    expect(directory().players.map((p) => p.name), ['Alex']);
  });

  testWidgets('a group is removed only once the question is answered', (
    tester,
  ) async {
    await run(tester, () => directory().saveGroup(PlayerGroup.create('Club')));
    directory().showGroups(true);
    await show(tester);
    await choose(tester, 'Group actions', 'Remove group…');
    expect(find.text('Remove group “Club”?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(directory().groups, hasLength(1));

    await choose(tester, 'Group actions', 'Remove group…');
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await settle(tester);
    expect(directory().groups, isEmpty);
  });

  testWidgets('Add players… offers only the people not in the group, and '
      'adds the one chosen', (tester) async {
    final alex = Player.create('Alex');
    final bea = Player.create('Bea');
    final group = PlayerGroup.create('Club').member(alex.id);
    await run(tester, () async {
      await directory().save(alex);
      await directory().save(bea);
      await directory().saveGroup(group);
    });
    directory().showGroup(group.id);
    await show(tester);
    await tester.tap(find.text('Add players…'));
    await tester.pumpAndSettle();
    expect(find.text('Add to Club'), findsOneWidget);
    final dialog = find.byType(Dialog);
    expect(find.descendant(of: dialog, matching: find.text('Alex')), findsNothing);
    await tester.tap(find.descendant(of: dialog, matching: find.text('Bea')));
    await settle(tester);
    expect(directory().group!.contains(bea.id), isTrue);
    expect(directory().group!.contains(alex.id), isTrue);
  });

  testWidgets('while a failed save waits, nothing is added and the save can '
      'be retried or let go', (tester) async {
    final alex = Player.create('Alex');
    await run(tester, () => directory().save(alex));
    store.throwOnSave = StateError('disk');
    await run(tester, () async {
      await directory().save(alex.edited({'notes': 'x'}), expected: alex);
    });
    expect(directory().needsRetry, isTrue);
    expect(directory().busy, isFalse);
    await show(tester);
    for (final label in ['Add player…', 'Paste players…']) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      );
      expect(
        tester.widget<ButtonStyleButton>(button.first).onPressed,
        isNull,
        reason: label,
      );
    }
    expect(find.text('Retry save'), findsOneWidget);
    expect(find.text('Discard failed edit and reload'), findsOneWidget);
    await tester.tap(find.text('Retry save'));
    await settle(tester);
    expect(directory().needsRetry, isFalse);
    expect(directory().players.single.text('notes'), 'x');
  });

  testWidgets('one downloaded game is offered for deletion and deleted once '
      'confirmed', (tester) async {
    const download = DocumentRef('/games_library/lichess_alex.pgn');
    const game =
        '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Result "1-0"]\n\n'
        '1. e4 e5 1-0\n';
    w.store.documents[download] = Opened(game, scriptedRevision(game));
    await run(
      tester,
      () => directory().save(Player.create('Alex').edited({'lichess': 'alex'})),
    );
    await show(tester);
    await settle(tester);
    await choose(tester, 'Player actions', 'Delete saved games…');
    await settle(tester);
    expect(
      find.text(
        'Moves 1 downloaded game to the recovery folder and deletes their '
        'analysis. Linked PGN files stay.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Delete games'));
    await settle(tester);
    expect(deletes.map((p) => p.name), ['Alex']);
  });

  testWidgets('ratings are offered only where there is a service to ask', (
    tester,
  ) async {
    await show(tester);
    expect(
      (await menu(tester)).keys,
      isNot(contains('Update US Chess ratings')),
    );
    final rated = Players(
      MemoryPlayers(),
      PendingWrites(),
      lookupRating: (id) async => (name: 'Alex', rating: 1500),
    );
    addTearDown(rated.dispose);
    await show(tester, players: rated);
    expect((await menu(tester))['Update US Chess ratings'], isNotNull);
  });

  testWidgets('a group study is offered to unlink only when there is one, '
      'and unlinking keeps the group', (tester) async {
    final group = PlayerGroup.create('Club');
    await run(tester, () => directory().saveGroup(group));
    directory().showGroup(group.id);
    await show(tester);
    expect((await menu(tester)).keys, isNot(contains('Unlink group study')));

    await run(
      tester,
      () => directory().saveGroup(
        directory().group!.edited({'study': '/studies/Club.pgn'}),
        expected: directory().group,
      ),
    );
    await tester.pumpAndSettle();
    await choose(tester, 'More actions', 'Unlink group study');
    await settle(tester);
    expect(directory().group!.study, isEmpty);
    expect(directory().group!.name, 'Club');
  });
}
