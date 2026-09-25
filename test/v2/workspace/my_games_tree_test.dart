import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:path/path.dart' as p;
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/storage/game_store.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:chess_auto_prep/v2/storage/my_games_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/local_games.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/my_games_fixture.dart';
import '../storage/store_fixture.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/scripted_explorer.dart';

/// A game of the user's on Lichess, played on [date].
String lichessGame(String id, String date, String moves, String result) =>
    '[Event "Rated blitz game"]\n[Site "https://lichess.org/$id"]\n'
    '[Date "$date"]\n[White "Me"]\n'
    '[Black "Rival"]\n[Result "$result"]\n\n$moves $result';

final older = lichessGame('Aaaa1111', '2026.01.01', '1. e4 e5', '1-0');
final newer = lichessGame('Bbbb2222', '2026.09.01', '1. d4 d5', '0-1');

/// The tactics archive's copy of [older], which is the same game.
final olderAgain = lichessGame('Aaaa1111', '2026.01.01', '1. e4 e5', '1-0');

/// A game only the old app's database has.
const archived =
    '[Event "Club"]\n[Date "2025.06.01"]\n[Result "1/2-1/2"]\n\n'
    '1. c4 c5 1/2-1/2';

void main() {
  late ScriptedDocumentStore files;
  late GamesCache cache;
  late ScriptedFiles boundary;
  late _Accounts accounts;
  late ScriptedGameStore database;
  late MyGamesTree tree;

  setUp(() {
    files = ScriptedDocumentStore();
    cache = GamesCache(files, folder: '/games_library');
    accounts = _Accounts();
    database = ScriptedGameStore();
    boundary = ScriptedFiles();
    tree = MyGamesTree(
      accounts: accounts,
      cache: cache,
      store: database,
      files: boundary,
    );
  });

  tearDown(() => tree.dispose());

  void saved(GameSite site, String user, List<String> games) {
    final text = '${games.join('\n\n')}\n';
    files.documents[cache.refFor(site, user)] = Opened(
      text,
      scriptedRevision(text),
    );
  }

  Future<void> built() async {
    tree.want();
    await settled(tree);
  }

  test('with no accounts and no database there is nothing, and it says '
      'where games come from', () async {
    await built();
    expect(tree.state, isA<TreeEmpty>());
    expect((tree.state as TreeEmpty).sentence, contains('Get games'));
    expect(database.asked.single, {GameCollections.tactics});
  });

  test('the downloaded games and the database\'s are one tree, each game '
      'once, newest first', () async {
    accounts.accounts[GameSite.lichess] = const Account('Me');
    saved(GameSite.lichess, 'Me', [older, newer]);
    database.answer = StoredGamesFound([
      StoredGame(collection: 'tactics', key: 'a', pgn: olderAgain),
      const StoredGame(collection: 'tactics', key: 'b', pgn: archived),
    ]);
    await built();
    expect(tree.state, isA<TreeBuilt>());
    expect(movesOf(tree.answerAt(Fen.initial)), ['d2d4', 'e2e4', 'c2c4']);
    final games = tree.answerAt(Fen.initial)!.games;
    expect(games.map((g) => g.id).take(2), [
      'lichess_Bbbb2222',
      'lichess_Aaaa1111',
    ]);
    expect(tree.summary, '3 games · Lichess, tactics archive');
    expect(tree.gamePgn('lichess_Bbbb2222'), newer);
  });

  test('the database is asked for the accounts\' library and Player '
      'analysis collections as the old app names them', () async {
    accounts.accounts[GameSite.chesscom] = const Account('Me');
    await built();
    expect(database.asked.single, {
      GameCollections.tactics,
      GameCollections.library(GameSite.chesscom, 'Me'),
      ...GameCollections.analysis(GameSite.chesscom, 'Me'),
    });
  });

  test('a database that cannot be read leaves the downloaded games, and '
      'says so beside them', () async {
    accounts.accounts[GameSite.lichess] = const Account('Me');
    saved(GameSite.lichess, 'Me', [older]);
    database.answer = const StoredGamesUnreadable('database is locked');
    await built();
    final state = tree.state as TreeBuilt;
    expect(state.notice, contains('could not be read'));
    expect(movesOf(tree.answerAt(Fen.initial)), ['e2e4']);
  });

  test(
    'a database that cannot be read with nothing downloaded says so',
    () async {
      database.answer = const StoredGamesUnreadable('file is not a database');
      await built();
      expect(
        (tree.state as TreeFailed).sentence,
        contains('could not be read'),
      );
    },
  );

  test('an unreadable download cannot become a partial tree', () async {
    accounts.accounts[GameSite.lichess] = const Account('Me');
    files.documents[cache.refFor(GameSite.lichess, 'Me')] = const Unreadable(
      'permission denied',
    );
    database.answer = const StoredGamesFound([
      StoredGame(collection: 'tactics', key: 'b', pgn: archived),
    ]);
    await built();
    expect(tree.state, isA<TreeFailed>());
    expect(tree.answerAt(Fen.initial), isNull);
  });

  test('a rebuilding tree does not authorize its old answers', () async {
    accounts.accounts[GameSite.lichess] = const Account('Me');
    saved(GameSite.lichess, 'Me', [older]);
    await built();
    saved(GameSite.lichess, 'Me', [older, newer]);
    tree.forget();
    expect(tree.state, isA<TreeUnbuilt>());
    expect(tree.answerAt(Fen.initial), isNull);
    expect(tree.gamePgn('lichess_Aaaa1111'), isNull);
    await built();
    expect(movesOf(tree.answerAt(Fen.initial)), ['d2d4', 'e2e4']);
    expect(database.asked, hasLength(2));
  });

  test(
    'failed account refresh never turns an archive into a complete tree',
    () async {
      accounts.accounts[GameSite.lichess] = const Account('Me');
      saved(GameSite.lichess, 'Me', [older]);
      await built();
      accounts.unavailable = true;
      database.answer = const StoredGamesFound([
        StoredGame(collection: 'tactics', key: 'b', pgn: archived),
      ]);
      tree.forget();
      await built();
      expect(tree.state, isA<TreeFailed>());
      expect(tree.answerAt(Fen.initial), isNull);
      expect(tree.gamePgn('lichess_Aaaa1111'), isNull);
      tree.want();
      expect(database.asked, hasLength(1));
      accounts.unavailable = false;
      tree.forget();
      await built();
      expect(tree.state, isA<TreeBuilt>());
    },
  );

  test(
    'all corpora including absence participate in one final fence',
    () async {
      accounts.accounts.addAll({
        GameSite.lichess: const Account('Me'),
        GameSite.chesscom: const Account('Other'),
      });
      saved(GameSite.lichess, 'Me', [older]);
      await built();
      final observed = boundary.additionalValidations.single;
      final present = cache.refFor(GameSite.lichess, 'Me');
      final absent = cache.refFor(GameSite.chesscom, 'Other');
      expect(observed.keys, unorderedEquals([present.path, absent.path]));
      expect(
        observed[present.path],
        (files.documents[present] as Opened).revision,
      );
      expect(observed[absent.path], isNull);
    },
  );

  test('an empty input must pass the final fence too', () async {
    accounts.accounts[GameSite.lichess] = const Account('Me');
    boundary.validateWith = (_, _) async => const RepertoireChanged();
    await built();
    expect(tree.state, isA<TreeFailed>());
    expect(boundary.additionalValidations.single.values.single, isNull);
  });

  test(
    'account admission during final validation prevents publication',
    () async {
      accounts.accounts[GameSite.lichess] = const Account('Me');
      saved(GameSite.lichess, 'Me', [older]);
      final entered = Completer<void>();
      final release = Completer<RepertoireValidation>();
      boundary.validateWith = (_, _) {
        entered.complete();
        return release.future;
      };
      tree.want();
      await entered.future;
      expect(tree.answerAt(Fen.initial), isNull);
      await accounts.setUsername(GameSite.lichess, 'Other');
      release.complete(const RepertoireCurrent());
      await settled(tree);
      expect(tree.state, isA<TreeFailed>());
      expect(tree.gamePgn('lichess_Aaaa1111'), isNull);
    },
  );

  test(
    'account admission immediately revokes already-published answers',
    () async {
      accounts.accounts[GameSite.lichess] = const Account('Me');
      saved(GameSite.lichess, 'Me', [older]);
      await built();
      final saving = accounts.setUsername(GameSite.lichess, 'Other');
      expect(tree.state, isA<TreeUnbuilt>());
      expect(tree.answerAt(Fen.initial), isNull);
      expect(tree.gamePgn('lichess_Aaaa1111'), isNull);
      expect(tree.summary, isNull);
      await saving;
    },
  );

  for (final dispose in [false, true]) {
    test(
      '${dispose ? "disposal" : "invalidation"} during the final fence cannot publish',
      () async {
        accounts.accounts[GameSite.lichess] = const Account('Me');
        saved(GameSite.lichess, 'Me', [older]);
        final entered = Completer<void>();
        final release = Completer<RepertoireValidation>();
        boundary.validateWith = (_, _) {
          entered.complete();
          return release.future;
        };
        final old = tree;
        old.want();
        await entered.future;
        if (dispose) {
          old.dispose();
          tree = MyGamesTree(
            accounts: accounts,
            cache: cache,
            store: database,
            files: boundary,
          );
        } else {
          old.forget();
        }
        release.complete(const RepertoireCurrent());
        await Future<void>.delayed(Duration.zero);
        expect(old.answerAt(Fen.initial), isNull);
        expect(old.gamePgn('lichess_Aaaa1111'), isNull);
        expect(old.state, isNot(isA<TreeBuilt>()));
      },
    );
  }

  for (final present in [false, true]) {
    test(
      'native final fence refuses ${present ? "same-byte replacement" : "new previously absent corpus"}',
      () async {
        final disk = await StoreFixture.create();
        addTearDown(disk.dispose);
        final nativeCache = GamesCache(
          disk.store,
          folder: p.join(disk.documents.path, 'games_library'),
        );
        final ref = nativeCache.refFor(GameSite.lichess, 'Me');
        await Directory(p.dirname(ref.path)).create(recursive: true);
        if (present) await disk.put(ref, older);
        accounts.accounts[GameSite.lichess] = const Account('Me');
        final archive = _HeldArchive();
        tree.dispose();
        tree = MyGamesTree(
          accounts: accounts,
          cache: nativeCache,
          store: archive,
          files: ChapterDirectory(
            Directory(p.join(disk.documents.path, 'repertoires')),
            recovery: disk.store.recovery,
          ),
        );
        tree.want();
        await archive.entered.future;
        if (present) {
          final replacement = File('${ref.path}.replacement');
          await replacement.writeAsString(older);
          await replacement.rename(ref.path);
        } else {
          await disk.put(ref, older);
        }
        archive.release.complete(const StoredGamesAbsent());
        await settled(tree);
        expect(tree.state, isA<TreeFailed>());
        expect(tree.answerAt(Fen.initial), isNull);
        tree.forget();
        tree.want();
        await settled(tree);
        expect(tree.state, isA<TreeBuilt>());
        expect(movesOf(tree.answerAt(Fen.initial)), ['e2e4']);
      },
      skip: !Platform.isLinux,
    );
  }

  test('games with no site id are told apart by their text', () {
    final corpus = myGamesCorpus(
      files: const [],
      stored: const [
        StoredGame(collection: 'tactics', key: 'x', pgn: archived),
        StoredGame(collection: 'library:lichess_me', key: 'y', pgn: archived),
        StoredGame(collection: 'analysis:player-1', key: 'z', pgn: '1. h4 *'),
      ],
    );
    expect(corpus.texts, [archived, '1. h4 *']);
    expect(corpus.ids.first, startsWith('pgn_'));
    expect(corpus.from, ['tactics archive', 'player analysis']);
  });
}

final class _Accounts implements AccountStore {
  final _inner = MemoryAccounts();
  bool unavailable = false;
  Map<GameSite, Account> get accounts => _inner.accounts;
  @override
  int get revision => _inner.revision;
  @override
  Future<AccountsRead> snapshot() async => unavailable
      ? const AccountsUnavailable('preferences are unavailable')
      : _inner.snapshot();
  @override
  Future<Map<GameSite, Account>> read() => _inner.read();
  @override
  Future<bool> setUsername(GameSite site, String? username) =>
      _inner.setUsername(site, username);
  @override
  Future<bool> setDownloaded(GameSite site, DateTime when) =>
      _inner.setDownloaded(site, when);
}

final class _HeldArchive implements GameStore {
  final entered = Completer<void>();
  final release = Completer<StoredGamesRead>();
  @override
  Future<StoredGamesRead> read(Set<String> collections) {
    if (!entered.isCompleted) entered.complete();
    return release.future;
  }
}
