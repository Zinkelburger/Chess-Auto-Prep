import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/features/my_games/game_book.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:chess_auto_prep/v2/storage/my_games_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_shelf.dart';

import 'my_games_fixture.dart';
import 'scripted_files.dart';
import 'scripted_store.dart';

/// A White repertoire against the Sicilian: 2.Nf3 and 3.d4.
const whiteSicilian = '''
// Color: White

[Event "Sicilian"]
[Result "*"]

1. e4 c5 2. Nf3 d6 3. d4 *

[Event "Sicilian"]
[Result "*"]

1. e4 c5 2. Nf3 e6 3. d4 *
''';

/// A Black repertoire: the Najdorf's first moves.
const najdorfBook = '''
// Color: Black

[Event "Najdorf"]
[Result "*"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 *
''';

final sicilianRef = ref('e4', 'Sicilian');
final najdorfRef = ref('Najdorf', 'Main');

/// One of "Me"'s Lichess games: [white] says which side they had.
String myGame(
  String id,
  String date,
  String moves, {
  bool white = true,
  String result = '1-0',
}) =>
    '''
[Event "Rated blitz game"]
[Site "https://lichess.org/$id"]
[Date "$date"]
[White "${white ? 'Me' : 'Rival'}"]
[Black "${white ? 'Rival' : 'Me'}"]
[Result "$result"]
[BlackElo "2105"]
[WhiteElo "2105"]
[UTCDate "$date"]
[UTCTime "10:00:00"]

$moves $result''';

/// The saved games, oldest first as a download appends them. Newest first
/// they are: a gap at 2...Nc6 (21st), 2.Nc3 twice (20th, 18th), a Black
/// game past the end of the Najdorf (19th), and another opening (17th).
final savedGames = [
  myGame('game0001', '2026.09.17', '1. d4 d5'),
  myGame('game0002', '2026.09.18', '1. e4 c5 2. Nc3'),
  myGame(
    'game0003',
    '2026.09.19',
    '1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4',
    white: false,
    result: '0-1',
  ),
  myGame('game0004', '2026.09.20', '1. e4 c5 2. Nc3 Nc6', result: '0-1'),
  myGame('game0005', '2026.09.21', '1. e4 c5 2. Nf3 Nc6 3. d4'),
];

/// The book over a scripted store: the two repertoires, "Me"'s saved
/// Lichess games and a Lichess account named "Me".
final class BookFixture {
  BookFixture({List<String>? games}) {
    final text = '${(games ?? savedGames).join('\n\n')}\n';
    store
      ..documents[sicilianRef] = Opened(
        whiteSicilian,
        scriptedRevision(whiteSicilian),
      )
      ..documents[najdorfRef] = Opened(
        najdorfBook,
        scriptedRevision(najdorfBook),
      )
      ..documents[gamesRef] = Opened(text, scriptedRevision(text));
  }

  final store = ScriptedDocumentStore();
  final files = ScriptedFiles(
    listing: Repertoires([
      folder('e4', ['Sicilian']),
      folder('Najdorf', ['Main']),
    ]),
  );
  final accounts = MemoryAccounts({GameSite.lichess: const Account('Me')});
  late final cache = GamesCache(store, folder: '/games_library');
  late final shelf = RepertoireShelf(files: files, documents: store);
  late final book = GameBook(accounts: accounts, cache: cache, shelf: shelf);

  /// Where "Me"'s Lichess games are saved.
  DocumentRef get gamesRef => cache.refFor(GameSite.lichess, 'Me');

  /// The saved games file as the book names it.
  ChapterRef get gamesFile => ChapterRef.at(gamesRef.path);

  /// Replaces the saved games, as a download would.
  void saveGames(List<String> games) {
    final text = '${games.join('\n\n')}\n';
    store.documents[gamesRef] = Opened(text, scriptedRevision(text));
  }

  void dispose() => book.dispose();
}
