import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/tactics/my_games.dart';
import 'package:chess_auto_prep/features/tactics/my_games_block.dart';
import 'package:chess_auto_prep/features/tactics/set_additions.dart';
import 'package:chess_auto_prep/features/tactics/tactics_set.dart';
import 'package:chess_auto_prep/storage/my_accounts.dart';
import 'package:chess_auto_prep/storage/my_games_files.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/document/document_saver.dart';
import 'package:chess_auto_prep/workspace/document/document_session.dart';
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

  test('either username failing to save is a failed save', () async {
    for (final site in GameSite.values) {
      fixture.accounts.rejectSite = site;
      expect(
        await fixture.games.saveUsernames(lichess: 'First', chesscom: 'Second'),
        isFalse,
        reason: '${site.label} was not kept',
      );
      expect(
        fixture.games.accountProblem,
        'Your account names could not be saved.',
      );
    }
    fixture.accounts.rejectSite = null;
    expect(
      await fixture.games.saveUsernames(lichess: 'First', chesscom: 'Second'),
      isTrue,
    );
    expect(fixture.games.accountProblem, isNull);
  });

  test('a store that throws on a username is a failed save', () async {
    fixture.accounts.throwing = true;
    expect(await fixture.games.saveUsernames(lichess: 'First'), isFalse);
    expect(
      fixture.games.accountProblem,
      'Your account names could not be saved.',
    );
    expect(fixture.games.accounts[GameSite.lichess]?.username, 'First');
  });

  test('a failed username save does not hold review back', () async {
    fixture.accounts.reject = true;
    await fixture.games.saveUsernames(lichess: 'Alice');
    expect(fixture.games.accountsUnsettled, isFalse);
    expect(fixture.games.accounts[GameSite.lichess]?.username, 'Alice');
  });

  testWidgets('a failed username save says so once; saving again clears it', (
    tester,
  ) async {
    fixture.accounts.reject = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: MyGamesBlock(games: fixture.games)),
      ),
    );
    await tester.tap(find.text('Add accounts…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Lichess username'),
      'First',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Your account names could not be saved.'), findsOneWidget);
    expect(find.textContaining('Retry'), findsNothing);
    fixture.accounts.reject = false;
    await fixture.games.saveUsernames(lichess: 'First');
    await tester.pumpAndSettle();
    expect(find.text('Your account names could not be saved.'), findsNothing);
    expect(
      fixture.accounts.saved.accounts[GameSite.lichess]?.username,
      'First',
    );
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
    ),
    engine: () async => const StartFailed('unused'),
    settings: settings,
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

  /// Whether a username write throws instead of answering.
  bool throwing = false;

  /// The one site whose username is refused, or null.
  GameSite? rejectSite;
  Completer<void>? held;
  final requested = <(GameSite, String?)>[];

  @override
  int get revision => saved.revision;
  @override
  Future<AccountsRead> snapshot() => saved.snapshot();

  @override
  Future<Map<GameSite, Account>> read() => saved.read();

  @override
  Future<bool> setDownloaded(
    GameSite site,
    DateTime when, {
    String? expectedUsername,
  }) => saved.setDownloaded(site, when, expectedUsername: expectedUsername);

  @override
  Future<bool> setUsername(GameSite site, String? username) async {
    requested.add((site, username));
    await held?.future;
    if (throwing) throw const FileSystemException('locked');
    return reject || site == rejectSite
        ? false
        : saved.setUsername(site, username);
  }
}
