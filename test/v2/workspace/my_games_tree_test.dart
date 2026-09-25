import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/storage/game_store.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:chess_auto_prep/v2/storage/my_games_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/local_games.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/my_games_fixture.dart';
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
  late MemoryAccounts accounts;
  late ScriptedGameStore database;
  late MyGamesTree tree;

  setUp(() {
    files = ScriptedDocumentStore();
    cache = GamesCache(files, folder: '/games_library');
    accounts = MemoryAccounts();
    database = ScriptedGameStore();
    tree = MyGamesTree(accounts: accounts, cache: cache, store: database);
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

  test('a saved-games file that cannot be read is left out', () async {
    accounts.accounts[GameSite.lichess] = const Account('Me');
    files.documents[cache.refFor(GameSite.lichess, 'Me')] = const Unreadable(
      'permission denied',
    );
    database.answer = const StoredGamesFound([
      StoredGame(collection: 'tactics', key: 'b', pgn: archived),
    ]);
    await built();
    expect(movesOf(tree.answerAt(Fen.initial)), ['c2c4']);
  });

  test('after new games come down the tree is read again, answering as it '
      'was meanwhile', () async {
    accounts.accounts[GameSite.lichess] = const Account('Me');
    saved(GameSite.lichess, 'Me', [older]);
    await built();
    saved(GameSite.lichess, 'Me', [older, newer]);
    tree.forget();
    expect(tree.state, isA<TreeUnbuilt>());
    expect(movesOf(tree.answerAt(Fen.initial)), ['e2e4']);
    await built();
    expect(movesOf(tree.answerAt(Fen.initial)), ['d2d4', 'e2e4']);
    expect(database.asked, hasLength(2));
  });

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

  test(
    'one account file that cannot be read leaves the other games in',
    () async {
      accounts.accounts[GameSite.lichess] = const Account('Me');
      files.documents[cache.refFor(GameSite.lichess, 'Me')] = const Unreadable(
        'permission denied',
      );
      database.answer = const StoredGamesFound([
        StoredGame(collection: 'tactics', key: 'b', pgn: archived),
      ]);
      await built();
      expect(tree.state, isA<TreeBuilt>());
      expect(movesOf(tree.answerAt(Fen.initial)), ['c2c4']);
    },
  );
}
