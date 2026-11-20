import 'dart:async';

import 'package:chess_auto_prep/chess/explorer_choice.dart';
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/storage/my_accounts.dart';
import 'package:chess_auto_prep/storage/my_games_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/explorer/game_fetcher.dart';
import 'package:chess_auto_prep/workspace/explorer/local_games.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/my_games_fixture.dart';
import '../support/scripted_explorer.dart';
import '../support/scripted_store.dart';

/// A game of the user's on Lichess, played on [date].
String lichessGame(String id, String date, String moves, String result) =>
    '[Event "Rated blitz game"]\n[Site "https://lichess.org/$id"]\n'
    '[Date "$date"]\n[White "Me"]\n'
    '[Black "Rival"]\n[Result "$result"]\n\n$moves $result';

final older = lichessGame('Aaaa1111', '2026.01.01', '1. e4 e5', '1-0');
final newer = lichessGame('Bbbb2222', '2026.09.01', '1. d4 d5', '0-1');

/// A game that names no site game.
const unnamed =
    '[Event "Club"]\n[Date "2025.06.01"]\n[Result "1/2-1/2"]\n\n'
    '1. c4 c5 1/2-1/2';

void main() {
  late ScriptedDocumentStore files;
  late GamesCache cache;
  late MemoryAccounts accounts;
  late MyGamesTree tree;

  setUp(() {
    files = ScriptedDocumentStore();
    cache = GamesCache(files, folder: '/games_library');
    accounts = MemoryAccounts();
    tree = MyGamesTree(accounts: accounts, cache: cache);
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

  test('with no accounts there is nothing, and it says where games come '
      'from', () async {
    await built();
    expect(tree.state, isA<TreeEmpty>());
    expect((tree.state as TreeEmpty).sentence, contains('Get games'));
  });

  test('every account\'s downloaded games are one tree, each game once, '
      'newest first', () async {
    accounts.accounts[GameSite.lichess] = const Account('Me');
    accounts.accounts[GameSite.chesscom] = const Account('Me');
    saved(GameSite.lichess, 'Me', [older, newer]);
    saved(GameSite.chesscom, 'Me', [older, unnamed]);
    await built();
    expect(tree.state, isA<TreeBuilt>());
    expect(movesOf(tree.answerAt(Fen.initial)), ['d2d4', 'e2e4', 'c2c4']);
    final games = tree.answerAt(Fen.initial)!.games;
    expect(games.map((g) => g.id).take(2), [
      'lichess_Bbbb2222',
      'lichess_Aaaa1111',
    ]);
    expect(tree.summary, '3 games · Lichess, Chess.com');
    expect(tree.gamePgn('lichess_Bbbb2222'), newer);
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
  });

  test(
    'an unreadable cache reports failure and keeps the last explorer',
    () async {
      accounts.accounts[GameSite.lichess] = const Account('Me');
      saved(GameSite.lichess, 'Me', [older]);
      await built();
      expect(tree.state, isA<TreeBuilt>());
      final game = tree.answerAt(Fen.initial)!.games.single.id;
      expect(tree.gamePgn(game), older);

      files.documents[cache.refFor(GameSite.lichess, 'Me')] = const Unreadable(
        'permission denied',
      );
      tree.forget();
      await built();
      expect(movesOf(tree.answerAt(Fen.initial)), ['e2e4']);
      expect(tree.gamePgn(game), older);
      final notice = switch (tree.state) {
        TreeFailed(:final sentence) => sentence,
        TreeBuilt(:final notice) => notice,
        _ => null,
      };
      expect(notice, isNotNull);
      expect(notice, isNotEmpty);
    },
  );

  test(
    'a failing account keeps its games while the other account updates',
    () async {
      accounts.accounts[GameSite.lichess] = const Account('Me');
      accounts.accounts[GameSite.chesscom] = const Account('Me');
      saved(GameSite.lichess, 'Me', [older]);
      saved(GameSite.chesscom, 'Me', [unnamed]);
      await built();
      expect(
        movesOf(tree.answerAt(Fen.initial)),
        unorderedEquals(['e2e4', 'c2c4']),
      );

      files.documents[cache.refFor(GameSite.lichess, 'Me')] = const Unreadable(
        'permission denied',
      );
      saved(GameSite.chesscom, 'Me', [unnamed, newer]);
      tree.forget();
      await built();
      expect(
        movesOf(tree.answerAt(Fen.initial)),
        unorderedEquals(['d2d4', 'e2e4', 'c2c4']),
      );
      expect(tree.gamePgn('lichess_Aaaa1111'), older);
      expect(tree.gamePgn('lichess_Bbbb2222'), newer);
      expect((tree.state as TreeBuilt).notice, contains('Lichess'));
    },
  );

  test('a readable duplicate supplies the current PGN and moves', () async {
    accounts.accounts[GameSite.lichess] = const Account('Me');
    accounts.accounts[GameSite.chesscom] = const Account('Me');
    saved(GameSite.lichess, 'Me', [older, newer]);
    saved(GameSite.chesscom, 'Me', [older]);
    await built();
    files.documents[cache.refFor(GameSite.lichess, 'Me')] = const Unreadable(
      'permission denied',
    );
    final updated = older.replaceFirst('1. e4 e5', '1. c4 c5');
    saved(GameSite.chesscom, 'Me', [updated]);
    tree.forget();
    await built();
    expect(tree.gamePgn('lichess_Aaaa1111'), updated);
    expect(tree.gamePgn('lichess_Bbbb2222'), newer);
    expect(await tree.readGamePgn('lichess_Aaaa1111'), updated);
    expect(await tree.readGamePgn('lichess_Bbbb2222'), isNull);
    expect(
      movesOf(tree.answerAt(Fen.initial)),
      unorderedEquals(['c2c4', 'd2d4']),
    );

    files.documents[cache.refFor(GameSite.chesscom, 'Me')] = const Unreadable(
      'permission denied',
    );
    tree.forget();
    await built();
    expect(tree.gamePgn('lichess_Aaaa1111'), updated);
  });

  test('opening a retained game copies the recovered PGN', () async {
    accounts.accounts[GameSite.lichess] = const Account('Me');
    saved(GameSite.lichess, 'Me', [older]);
    await built();
    final game = tree.answerAt(Fen.initial)!.games.single;
    final fetcher = gamesOver(files, myGames: tree);
    addTearDown(fetcher.dispose);
    Future<GameKeep> open() =>
        fetcher.keep(game, source: ExplorerSource.myGames, ply: 1);

    final source = cache.refFor(GameSite.lichess, 'Me');
    final edited = older.replaceFirst('1. e4', '1. e4 {Keep this comment}');
    saved(GameSite.lichess, 'Me', [edited]);
    final committed = files.documents[source]!;
    tree.forget();
    files.documents[source] = const Unreadable('permission denied');
    await built();
    expect(tree.answerAt(Fen.initial)!.games.single.id, game.id);
    expect(await open(), isA<GameNotKept>());
    expect(files.documents.keys, [source]);

    files.documents[source] = committed;
    final kept = await open() as GameKept;
    expect((files.documents[kept.ref] as Opened).text, edited);

    files.documents[source] = const Unreadable('permission denied');
    expect((await open() as GameKept).ref, kept.ref);
    expect((files.documents[kept.ref] as Opened).text, edited);
  });

  test('a change during a retained game read prevents a stale copy', () async {
    accounts.accounts[GameSite.lichess] = const Account('Me');
    saved(GameSite.lichess, 'Me', [older]);
    await built();
    final game = tree.answerAt(Fen.initial)!.games.single;
    final source = cache.refFor(GameSite.lichess, 'Me');
    files.documents[source] = const Unreadable('permission denied');
    tree.forget();
    await built();

    saved(GameSite.lichess, 'Me', [older]);
    final gate = files.readEarly = Completer<void>();
    final collection = ScriptedDocumentStore();
    final fetcher = gamesOver(collection, myGames: tree);
    addTearDown(fetcher.dispose);
    final opening = fetcher.keep(game, source: ExplorerSource.myGames, ply: 1);
    await Future<void>.delayed(Duration.zero);
    expect(files.readEarly, isNull);
    saved(GameSite.lichess, 'Me', [newer]);
    tree.forget();
    gate.complete();
    expect(await opening, isA<GameNotKept>());
    expect(collection.documents, isEmpty);
  });

  test('games with no site id are told apart by their text', () {
    final corpus = myGamesCorpus(
      files: [
        (GameSite.lichess, [unnamed, unnamed, '1. h4 *']),
      ],
    );
    expect(corpus.texts, [unnamed, '1. h4 *']);
    expect(corpus.ids.first, startsWith('pgn_'));
    expect(corpus.from, ['Lichess']);
  });

  test('a retained game without a site ID reopens only by its text', () async {
    accounts.accounts[GameSite.chesscom] = const Account('Me');
    saved(GameSite.chesscom, 'Me', [unnamed]);
    await built();
    final id = tree.answerAt(Fen.initial)!.games.single.id;
    files.documents[cache.refFor(GameSite.chesscom, 'Me')] = const Unreadable(
      'permission denied',
    );
    tree.forget();
    await built();

    saved(GameSite.chesscom, 'Me', [unnamed.replaceFirst('Club', 'Other')]);
    expect(await tree.readGamePgn(id), isNull);
    saved(GameSite.chesscom, 'Me', [older, unnamed]);
    expect(await tree.readGamePgn(id), unnamed);
  });

  test(
    'one account file that cannot be read leaves the other games in',
    () async {
      accounts.accounts[GameSite.lichess] = const Account('Me');
      accounts.accounts[GameSite.chesscom] = const Account('Me');
      files.documents[cache.refFor(GameSite.lichess, 'Me')] = const Unreadable(
        'permission denied',
      );
      saved(GameSite.chesscom, 'Me', [unnamed]);
      await built();
      expect(tree.state, isA<TreeBuilt>());
      expect(movesOf(tree.answerAt(Fen.initial)), ['c2c4']);
    },
  );

  test(
    'reading counts from nothing: none of none, then none of the games',
    () async {
      accounts.accounts[GameSite.lichess] = const Account('Me');
      saved(GameSite.lichess, 'Me', [older, newer]);
      final reading = <(int, int)>[];
      tree.addListener(() {
        if (tree.state case TreeReading(:final done, :final total)) {
          reading.add((done, total));
        }
      });
      await built();
      expect(reading.first, (0, 0));
      expect(reading, contains((0, 2)));
    },
  );

  test('a closed tree stays quiet when the games change', () {
    final closed = MyGamesTree(accounts: accounts, cache: cache)..dispose();
    closed.forget();
    expect(closed.state, isA<TreeUnbuilt>());
  });
}
