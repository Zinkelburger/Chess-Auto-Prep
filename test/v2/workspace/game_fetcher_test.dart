import 'package:chess_auto_prep/v2/chess/explorer_answer.dart';
import 'package:chess_auto_prep/v2/chess/explorer_choice.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/game_fetcher.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_explorer.dart';
import '../support/scripted_store.dart';

void main() {
  late ScriptedDocumentStore store;
  late ScriptedExplorerApi lichess;
  late ScriptedBook book;
  late GameFetcher games;
  final game = startAnswer.games.single;

  setUp(() {
    store = ScriptedDocumentStore();
    lichess = ScriptedExplorerApi();
    book = ScriptedBook(present: true);
    games = gamesOver(store, lichess: lichess, book: book);
  });

  tearDown(() => games.dispose());

  test('a listed game is fetched and kept as a file in the collections '
      'folder, to open at the ply it was listed at', () async {
    final kept =
        await games.keep(game, source: ExplorerSource.masters, ply: 1)
            as GameKept;
    expect(kept.ply, 1);
    expect(
      kept.ref.path,
      '$explorerCollections/explorer games/'
      'Carlsen, M - Nakamura, H 2024 (masters abcd1234).pgn',
    );
    expect(lichess.gamesAsked.single, ('abcd1234', true));
    expect(store.documents[kept.ref], isA<Opened>());
    // A second click on the same game opens the file already there.
    expect(
      await games.keep(game, source: ExplorerSource.masters, ply: 1),
      isA<GameKept>(),
    );
    lichess.pgn = null;
    expect(
      (await games.keep(game, source: ExplorerSource.masters, ply: 1)
              as GameNotKept)
          .sentence,
      'Could not fetch that game.',
    );
  });

  test('the game being fetched is named until it arrives', () async {
    final seen = <String?>[];
    games.addListener(() => seen.add(games.fetching));
    await games.keep(game, source: ExplorerSource.lichess, ply: 0);
    expect(seen, ['abcd1234', null]);
    expect(lichess.gamesAsked.single, ('abcd1234', false));
  });

  test('a TWIC game comes from the book', () async {
    await games.keep(game, source: ExplorerSource.twic, ply: 0);
    expect(book.gamesAsked, ['abcd1234']);
    expect(lichess.gamesAsked, isEmpty);
  });

  test('a name that cannot be a file name is made one', () {
    const game = ExplorerGame(
      id: '7',
      white: 'A/B: "C"',
      black: 'D?',
      result: '*',
    );
    expect(gameFileName(game, ExplorerSource.twic), 'A_B_ _C_ - D_ (twic 7)');
  });
}
