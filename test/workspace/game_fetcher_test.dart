import 'package:chess_auto_prep/chess/explorer_answer.dart';
import 'package:chess_auto_prep/chess/explorer_choice.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/explorer/game_fetcher.dart';
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

  test('a fetch that fails on the way ends, so the other rows can be '
      'fetched', () async {
    book.throwing = StateError('the database went away');
    final seen = <String?>[];
    games.addListener(() => seen.add(games.fetching));
    final kept = await games.keep(game, source: ExplorerSource.twic, ply: 0);
    expect((kept as GameNotKept).sentence, 'Could not fetch that game.');
    expect(seen, [game.id, null]);
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

  test('a reused TWIC id never opens the wrong saved game', () async {
    const listed = ExplorerGame(
      id: '1',
      white: 'Alice',
      black: 'Bob',
      year: 2024,
      result: '*',
    );
    const tags = '[White "Alice"]\n[Black "Bob"]\n[Date "2024.01.01"]\n\n';
    const first = '${tags}1. e4 e5 *\n';
    const replacement = '${tags}1. d4 d5 *\n';
    book.pgn = first;
    final saved =
        await games.keep(listed, source: ExplorerSource.twic, ply: 0)
            as GameKept;

    final rebuilt = ScriptedBook(present: true)..pgn = replacement;
    final reopened = gamesOver(store, book: rebuilt);
    addTearDown(reopened.dispose);
    final result = await reopened.keep(
      listed,
      source: ExplorerSource.twic,
      ply: 0,
    );
    expect((store.documents[saved.ref] as Opened).text, first);
    if (result case GameKept(:final ref)) {
      expect((store.documents[ref] as Opened).text, replacement);
    }
  });

  test('long names preserve distinct game identities', () async {
    ExplorerGame longGame(String id) =>
        ExplorerGame(id: id, white: 'A' * 80, black: 'B' * 80, result: '*');
    final first =
        await games.keep(
              longGame('one'),
              source: ExplorerSource.masters,
              ply: 0,
            )
            as GameKept;
    final second =
        await games.keep(
              longGame('two'),
              source: ExplorerSource.masters,
              ply: 0,
            )
            as GameKept;
    expect(first.ref.path, isNot(second.ref.path));
    expect(store.documents, hasLength(2));
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

  test('a name of a hundred characters is kept whole; a longer one is cut '
      'and named by its game', () {
    ExplorerGame named(int white) =>
        ExplorerGame(id: '1', white: 'A' * white, black: 'B' * 40, result: '*');
    final hundred = gameFileName(named(45), ExplorerSource.masters);
    expect(hundred, '${'A' * 45} - ${'B' * 40} (masters 1)');
    expect(hundred, hasLength(100));
    final longer = gameFileName(named(46), ExplorerSource.masters);
    expect(longer, startsWith('A' * 33));
    expect(longer, isNot(contains('masters 1')));
  });

  test('a game that arrives after the fetcher went is not kept', () async {
    final gone = gamesOver(store, lichess: lichess, book: book);
    final keeping = gone.keep(game, source: ExplorerSource.masters, ply: 0);
    gone.dispose();
    expect(await keeping, isA<GameNotKept>());
    expect(store.documents, isEmpty);
  });
}
