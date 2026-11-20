import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/tactics/my_games.dart';
import 'package:chess_auto_prep/features/tactics/my_games_block.dart';
import 'package:chess_auto_prep/features/tactics/set_additions.dart';
import 'package:chess_auto_prep/features/tactics/tactics_actions.dart';
import 'package:chess_auto_prep/features/tactics/tactics_set.dart';
import 'package:chess_auto_prep/net/recent_games.dart';
import 'package:chess_auto_prep/storage/my_accounts.dart';
import 'package:chess_auto_prep/storage/my_games_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/ui/app_action.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/document/document_saver.dart';
import 'package:chess_auto_prep/workspace/document/document_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/my_games_fixture.dart';
import '../../support/scripted_store.dart';
import '../../support/tactics_fixture.dart';

/// A site whose download waits until the test lets it answer.
final class _HeldSite implements RecentGames {
  _HeldSite(this.answer);

  @override
  GameSite get site => GameSite.lichess;
  final GamesFetch answer;
  Completer<void> gate = Completer<void>();

  @override
  Future<GamesFetch> recent(String username, {required int max}) async {
    await gate.future;
    return answer;
  }
}

/// The top of the Tactics column over the real review, with a site the
/// test holds and an engine that never starts.
void main() {
  late ScriptedDocumentStore store;
  late DocumentSaver saver;
  late DocumentSession session;
  late SettingsStore settings;
  late TacticsSet set;
  late MemoryAccounts accounts;
  late _HeldSite site;
  late MyGames games;
  late Directory folder;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('v2-my-games-block-');
    store = ScriptedDocumentStore()
      ..documents[tacticsRef] = Opened(tacticsSet, scriptedRevision(tacticsSet));
    saver = DocumentSaver(store, delay: Duration.zero);
    session = DocumentSession(store, saver);
    settings = SettingsStore();
    set = TacticsSet(
      documents: store,
      session: session,
      settings: settings,
      ref: tacticsRef,
    );
    accounts = MemoryAccounts();
    site = _HeldSite(const GamesFetched([scholarsMate]));
    games = MyGames(
      accounts: accounts,
      sites: [site],
      cache: GamesCache(store, folder: folder.path),
      set: SetAdditions(
        documents: store,
        session: session,
        saver: saver,
        set: set,
      ),
      engine: () async => const StartFailed('no Stockfish'),
      settings: settings,
    );
  });

  tearDown(() {
    if (!site.gate.isCompleted) site.gate.complete();
    games.dispose();
    set.dispose();
    session.dispose();
    saver.dispose();
    settings.dispose();
    folder.deleteSync(recursive: true);
  });

  /// Lets the review's file work happen, a little at a time, until [done].
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pump();
    expect(done(), isTrue);
  }

  Future<void> pumpBlock(
    WidgetTester tester, {
    bool primary = true,
    bool forPuzzles = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: MyGamesBlock(
            games: games,
            primary: primary,
            forPuzzles: forPuzzles,
          ),
        ),
      ),
    );
  }

  Future<void> withAccount(WidgetTester tester) async {
    accounts.accounts[GameSite.lichess] = const Account('Me');
    await games.load();
    await tester.pump();
  }

  ButtonStyleButton button(WidgetTester tester, String label) =>
      tester.widget<ButtonStyleButton>(
        find
            .ancestor(
              of: find.text(label),
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            )
            .first,
      );

  bool chipOn(WidgetTester tester, String label) =>
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, label)).onSelected !=
      null;

  testWidgets('with no username it asks for one, in the words of the mode, '
      'filled only where it is the thing to do', (tester) async {
    await pumpBlock(tester);
    expect(
      find.text(
        'Add your Lichess or Chess.com username to turn your mistakes into '
        'puzzles.',
      ),
      findsOneWidget,
    );
    expect(button(tester, 'Add accounts…'), isA<FilledButton>());
    await pumpBlock(tester, primary: false, forPuzzles: false);
    expect(
      find.text(
        'Add your Lichess or Chess.com username to browse and review your '
        'games.',
      ),
      findsOneWidget,
    );
    expect(button(tester, 'Add accounts…'), isA<OutlinedButton>());
  });

  testWidgets('the accounts dialog keeps the names typed, trimmed, and '
      'Enter saves them', (tester) async {
    await withAccount(tester);
    await pumpBlock(tester);
    expect(find.text('Me'), findsOneWidget);
    expect(find.byTooltip('Lichess username'), findsOneWidget);
    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Me'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Chess.com username'),
      '  Other  ',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(accounts.accounts[GameSite.chesscom]?.username, 'Other');
    expect(accounts.accounts[GameSite.lichess]?.username, 'Me');
    expect(find.text('Other'), findsOneWidget);

    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(accounts.accounts, hasLength(2), reason: 'backing out keeps them');
  });

  testWidgets('a time control can be turned off, but never the last one', (
    tester,
  ) async {
    await withAccount(tester);
    await pumpBlock(tester);
    await tester.tap(find.text('Bullet'));
    await tester.pump();
    expect(games.speeds, isNot(contains(GameSpeed.bullet)));
    await tester.tap(find.text('Bullet'));
    await tester.pump();
    expect(games.speeds, contains(GameSpeed.bullet));
    games.setSpeeds({GameSpeed.blitz});
    await tester.pump();
    expect(chipOn(tester, 'Blitz'), isFalse, reason: 'the only one on');
    expect(chipOn(tester, 'Rapid'), isTrue);
  });

  testWidgets('Get games runs the review: Pause while it runs, nothing to '
      'change meanwhile, and Resume after', (tester) async {
    await withAccount(tester);
    await pumpBlock(tester);
    expect(find.byTooltip(RegExp('^Download your new games')), findsOne);
    await tester.tap(find.text('Get games'));
    await settle(tester, () => games.running);
    expect(find.text('Getting your recent games…'), findsOneWidget);
    expect(button(tester, 'Change').onPressed, isNull);
    expect(chipOn(tester, 'Blitz'), isFalse);
    expect(
      find.byTooltip(
        'Stop after the game being looked at; press again to carry on',
      ),
      findsOne,
    );

    await tester.tap(find.text('Pause'));
    await tester.pump();
    expect(find.text('Pausing…'), findsOneWidget);
    expect(button(tester, 'Pause').onPressed, isNull);

    site.gate.complete();
    await settle(tester, () => games.status is MyGamesPaused);
    expect(find.text('Paused — 1 game left'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.byTooltip('Carry on with the 1 games still to look at'), findsOne);
    expect(button(tester, 'Change').onPressed, isNotNull);
  });

  testWidgets('a failed review says so in the error colour', (tester) async {
    await withAccount(tester);
    await pumpBlock(tester);
    site.gate.complete();
    await tester.tap(find.text('Get games'));
    await settle(tester, () => games.status is MyGamesFailed);
    await tester.pump();
    final line = tester.widget<Text>(find.textContaining('Analysis failed'));
    final context = tester.element(find.byType(MyGamesBlock));
    expect(line.style?.color, Theme.of(context).colorScheme.error);
  });

  testWidgets('the menu\'s My games entries follow the button: Pause while '
      'it runs, Resume after, and no accounts dialog meanwhile', (
    tester,
  ) async {
    var asked = 0;
    List<String> labels() => [
      for (final action in myGamesActions(games, onAccounts: () => asked++))
        action.label,
    ];
    AppAction named(String label) => myGamesActions(
      games,
      onAccounts: () => asked++,
    ).firstWhere((action) => action.label == label);

    await withAccount(tester);
    await pumpBlock(tester);
    expect(labels(), ['Get games', 'My accounts…']);
    named('Get games').run!();
    await settle(tester, () => games.running);
    expect(labels(), ['Pause', 'My accounts…']);
    expect(named('My accounts…').run, isNull);
    named('Pause').run!();
    site.gate.complete();
    await settle(tester, () => games.status is MyGamesPaused);
    expect(games.queued, 1);
    expect(labels(), ['Resume', 'My accounts…']);
    named('My accounts…').run!();
    expect(asked, 1);
  });
}
