/// Shared fixtures for the master-practice tests: a five-game "corpus" and
/// a handful of my own games that meet it in different ways.
library;

import 'package:chess_auto_prep/features/games/models/recent_game.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';

/// Three Najdorfs (6.Be3 twice, 6.Bg5 once), one very long Breyer, and one
/// Grünfeld nobody of mine plays.
const masterPgn = '''
[Event "Tata Steel"]
[Site "Wijk aan Zee"]
[Date "2026.01.21"]
[White "Carlsen,Magnus"]
[Black "Nakamura,Hikaru"]
[Result "1-0"]
[WhiteElo "2830"]
[BlackElo "2790"]
[ECO "B90"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 e5 7. Nb3 Be6 1-0

[Event "Prague Open"]
[Site "Prague"]
[Date "2026.01.20"]
[White "Novak,Jan"]
[Black "Svoboda,Petr"]
[Result "0-1"]
[WhiteElo "2410"]
[BlackElo "2505"]
[ECO "B94"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Bg5 e6 0-1

[Event "Sinquefield Cup"]
[Site "Saint Louis"]
[Date "2025.03.02"]
[White "So,Wesley"]
[Black "Caruana,Fabiano"]
[Result "1/2-1/2"]
[WhiteElo "2760"]
[BlackElo "2800"]
[ECO "B90"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 Ng4 1/2-1/2

[Event "Candidates"]
[Site "Toronto"]
[Date "2024.04.10"]
[White "Gukesh,D"]
[Black "Nepomniachtchi,Ian"]
[Result "1/2-1/2"]
[WhiteElo "2743"]
[BlackElo "2758"]
[ECO "C95"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 6. Re1 b5 7. Bb3 d6 8. c3 O-O 9. h3 Nb8 10. d4 Nbd7 11. Nbd2 Bb7 12. Bc2 Re8 13. Nf1 Bf8 14. Ng3 g6 15. a4 c5 16. d5 c4 17. Bg5 h6 18. Be3 Nc5 1/2-1/2

[Event "Prague Open"]
[Site "Prague"]
[Date "2026.01.19"]
[White "Svoboda,Petr"]
[Black "Novak,Jan"]
[Result "1/2-1/2"]
[WhiteElo "2505"]
[BlackElo "2410"]
[ECO "D85"]

1. d4 Nf6 2. c4 g6 3. Nc3 d5 4. cxd5 Nxd5 1/2-1/2
''';

const _najdorfToMove6 = [
  'e4',
  'c5',
  'Nf3',
  'd6',
  'd4',
  'cxd4',
  'Nxd4',
  'Nf6',
  'Nc3',
  'a6',
];

RecentGame myGame({
  required String id,
  required String opponent,
  required bool? meWhite,
  required List<String> sans,
  String result = '1-0',
  DateTime? date,
  String? opening,
}) {
  final white = meWhite == true ? 'me' : opponent;
  final black = meWhite == false
      ? 'me'
      : (meWhite == null ? 'other' : opponent);
  return RecentGame(
    record: GameRecord(
      pgn: '',
      headers: {
        'White': white,
        'Black': black,
        'Result': result,
        'TimeControl': '600+0',
        'Opening': ?opening,
      },
      date: date ?? DateTime(2026, 8, 1),
      speed: GameSpeed.rapid,
      dedupKey: id,
    ),
    platform: GamesPlatform.lichess,
    cachePath: '/tmp/lichess_me.pgn',
    myUsername: 'me',
    meWhite: meWhite,
    sans: sans,
  );
}

/// I play 6.Bc4 twice as White; once an opponent plays it against me; one
/// game runs past the end of the corpus's longest Najdorf; one game names
/// neither of my accounts; one opens 1.b4, which no master game here does;
/// and one follows the Breyer past the book's depth.
List<RecentGame> myGames() => [
  myGame(
    id: 'a',
    opponent: 'bob',
    meWhite: true,
    sans: [..._najdorfToMove6, 'Bc4', 'e6'],
    date: DateTime(2026, 8, 3),
    opening: 'Sicilian Defense: Najdorf Variation',
  ),
  myGame(
    id: 'b',
    opponent: 'carl',
    meWhite: false,
    sans: [..._najdorfToMove6, 'Bc4', 'e6'],
    result: '0-1',
    date: DateTime(2026, 8, 2),
  ),
  myGame(
    id: 'c',
    opponent: 'dan',
    meWhite: true,
    sans: [..._najdorfToMove6, 'Bc4', 'e6'],
    result: '1/2-1/2',
    date: DateTime(2026, 8, 1),
  ),
  myGame(
    id: 'd',
    opponent: 'eve',
    meWhite: false,
    sans: [..._najdorfToMove6, 'Be3', 'e5', 'Nb3', 'Be6', 'f3', 'Be7'],
    date: DateTime(2026, 7, 30),
  ),
  myGame(
    id: 'e',
    opponent: 'fay',
    meWhite: null,
    sans: const ['e4', 'e5'],
    date: DateTime(2026, 7, 29),
  ),
  myGame(
    id: 'f',
    opponent: 'gus',
    meWhite: true,
    sans: const ['b4', 'd5'],
    date: DateTime(2026, 7, 28),
  ),
  myGame(
    id: 'g',
    opponent: 'hal',
    meWhite: true,
    sans: const [
      'e4',
      'e5',
      'Nf3',
      'Nc6',
      'Bb5',
      'a6',
      'Ba4',
      'Nf6',
      'O-O',
      'Be7',
      'Re1',
      'b5',
      'Bb3',
      'd6',
      'c3',
      'O-O',
      'h3',
      'Nb8',
      'd4',
      'Nbd7',
      'Nbd2',
      'Bb7',
      'Bc2',
      'Re8',
      'Nf1',
      'Bf8',
      'Ng3',
      'g6',
      'a4',
      'c5',
      'd5',
      'c4',
      'Bg5',
      'h6',
      'Be3',
      'Nc5',
    ],
    date: DateTime(2026, 7, 27),
  ),
];
