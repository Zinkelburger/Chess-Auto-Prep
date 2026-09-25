import 'dart:async';

import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/features/tactics/my_games.dart';
import 'package:chess_auto_prep/v2/features/tactics/my_games_block.dart';
import 'package:chess_auto_prep/v2/features/tactics/set_additions.dart';
import 'package:chess_auto_prep/v2/features/tactics/tactics_set.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:chess_auto_prep/v2/storage/my_games_files.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/my_games_fixture.dart';
import '../../support/scripted_store.dart';
import '../../support/tactics_fixture.dart';

void main() {
  late _Fixture fixture;
  setUp(() => fixture = _Fixture());
  tearDown(() => fixture.dispose());

  test(
    'saving the requested username pair again clears persistence failure',
    () async {
      fixture.accounts.reject = true;
      expect(
        await fixture.games.saveUsernames(lichess: 'First', chesscom: 'Second'),
        isFalse,
      );
      fixture.accounts.reject = false;
      expect(
        await fixture.games.saveUsernames(lichess: 'First', chesscom: 'Second'),
        isTrue,
      );
      expect(await fixture.pending.settle(), isNull);
    },
  );

  test('accepted usernames survive disposal and reject new requests', () async {
    fixture.accounts.reject = true;
    fixture.accounts.held = Completer<void>();
    final saving = fixture.games.saveUsernames(
      lichess: ' Alice ',
      chesscom: 'Bob',
    );
    await pumpEventQueue();
    fixture.disposeGames();
    fixture.accounts.held!.complete();
    expect(await saving, isFalse);
    expect(await fixture.games.saveUsernames(lichess: 'Carol'), isFalse);
    fixture.accounts.reject = false;
    await fixture.games.retryUsernames();
    expect(
      fixture.accounts.saved.accounts[GameSite.lichess]?.username,
      'Alice',
    );
    expect(fixture.accounts.saved.accounts[GameSite.chesscom]?.username, 'Bob');
    expect(await fixture.pending.settle(), isNull);
  });

  test(
    'game review cannot start while accepted usernames need saving',
    () async {
      fixture.accounts.reject = true;
      await fixture.games.saveUsernames(lichess: 'Alice');
      expect(fixture.games.accountsUnsettled, isTrue);
      await fixture.games.start();
      expect(fixture.games.status, isA<MyGamesIdle>());
      fixture.accounts.reject = false;
      await fixture.games.retryUsernames();
      expect(fixture.games.accountsUnsettled, isFalse);
    },
  );

  testWidgets('failed username save keeps a usable retry after dialog closes', (
    tester,
  ) async {
    fixture.accounts.reject = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: MyGamesBlock(games: fixture.games)),
      ),
    );
    await tester.tap(find.text('Add accounts'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Lichess username'),
      'First',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Chess.com username'),
      'Second',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Retry save'), findsOneWidget);
    fixture.accounts.reject = false;
    await tester.tap(find.text('Retry save'));
    await tester.pumpAndSettle();
    expect(
      fixture.accounts.saved.accounts[GameSite.lichess]?.username,
      'First',
    );
    expect(
      fixture.accounts.saved.accounts[GameSite.chesscom]?.username,
      'Second',
    );
    expect(find.text('Retry save'), findsNothing);
    expect(await fixture.pending.settle(), isNull);
  });
}

final class _Fixture {
  final accounts = _Accounts();
  final pending = PendingWrites();
  final documents = ScriptedDocumentStore();
  late final saver = DocumentSaver(documents);
  late final session = DocumentSession(documents, saver);
  final settings = SettingsStore();
  late final set = TacticsSet(
    documents: documents,
    session: session,
    settings: settings,
    ref: tacticsRef,
  );
  late final games = MyGames(
    accounts: accounts,
    pendingWrites: pending,
    sites: const [],
    cache: GamesCache(documents, folder: '/Documents/games_library'),
    set: SetAdditions(
      documents: documents,
      session: session,
      saver: saver,
      set: set,
      older: () async => {},
    ),
    engine: () async => const StartFailed('unused'),
  );
  bool gamesDisposed = false;

  void disposeGames() {
    if (gamesDisposed) return;
    gamesDisposed = true;
    games.dispose();
  }

  void dispose() {
    disposeGames();
    set.dispose();
    session.dispose();
    saver.dispose();
    settings.dispose();
  }
}

final class _Accounts implements AccountStore {
  final saved = MemoryAccounts();
  bool reject = false;
  Completer<void>? held;
  final requested = <(GameSite, String?)>[];

  @override
  int get revision => saved.revision;
  @override
  Future<AccountsRead> snapshot() => saved.snapshot();

  @override
  Future<Map<GameSite, Account>> read() => saved.read();

  @override
  Future<bool> setDownloaded(GameSite site, DateTime when) =>
      saved.setDownloaded(site, when);

  @override
  Future<bool> setUsername(GameSite site, String? username) async {
    requested.add((site, username));
    await held?.future;
    return reject ? false : saved.setUsername(site, username);
  }
}
