import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/net/lichess_explorer.dart';
import 'package:chess_auto_prep/v2/storage/master_book.dart';
import 'package:chess_auto_prep/v2/workspace/explorer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_explorer.dart';

void main() {
  late ScriptedExplorerApi lichess;
  late ScriptedBook book;
  late ScriptedLocalGames thisFile;
  late ScriptedLocalGames myGames;
  late ExplorerDatabases databases;

  ExplorerDatabases over(ScriptedBook book) => ExplorerDatabases(
    lichess: lichess,
    book: book,
    thisFile: thisFile,
    myGames: myGames,
  );

  setUp(() {
    lichess = ScriptedExplorerApi();
    book = ScriptedBook(present: true);
    thisFile = ScriptedLocalGames();
    myGames = ScriptedLocalGames();
    databases = over(book);
  });

  test('TWIC is asked on this machine, the others over the network', () async {
    const twic = ExplorerChoice(
      source: ExplorerSource.twic,
      classicalOnly: true,
    );
    final (fromBook, _) = await databases.ask(Fen.initial, twic);
    expect(fromBook, same(startAnswer));
    expect(book.asked.single, (Fen.initial, true));
    expect(lichess.asked, isEmpty);
    await databases.ask(Fen.initial, ExplorerChoice.defaults);
    expect(lichess.asked, hasLength(1));
  });

  test('a missing book and an unreachable network each say so', () async {
    book = ScriptedBook(answer: (_, _) => const BookAbsent());
    lichess.answer = (_) =>
        const ExplorerNotFetched(ExplorerProblem.unreachable);
    databases = over(book);
    final (_, noBook) = await databases.ask(
      Fen.initial,
      const ExplorerChoice(source: ExplorerSource.twic),
    );
    expect(noBook, 'There is no master database on this machine.');
    final (_, offline) = await databases.ask(
      Fen.initial,
      ExplorerChoice.defaults,
    );
    expect(offline, ExplorerProblem.unreachable.sentence);
    databases = over(ScriptedBook(present: true));
    final (_, offlineWithBook) = await databases.ask(
      Fen.initial,
      ExplorerChoice.defaults,
    );
    expect(offlineWithBook, endsWith('TWIC works offline.'));
  });

  test('a game My games lists is its kept PGN; one of This file is not '
      'fetched', () async {
    myGames.pgns['lichess_abcd1234'] = '[Event "Mine"]\n\n1. e4 1-0\n';
    const game = ExplorerGame(
      id: 'lichess_abcd1234',
      white: 'Me',
      black: 'You',
      result: '1-0',
    );
    expect(
      await databases.gamePgn(game, ExplorerSource.myGames),
      startsWith('[Event "Mine"]'),
    );
    expect(await databases.gamePgn(game, ExplorerSource.thisFile), isNull);
    expect(lichess.gamesAsked, isEmpty);
  });
}
