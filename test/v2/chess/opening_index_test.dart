import 'package:chess_auto_prep/v2/chess/explorer_answer.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/opening_index.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// A game of [moves] ending [result], with players and a date.
String game(
  String moves,
  String result, {
  String white = 'W',
  String black = 'B',
}) =>
    '[White "$white"]\n[Black "$black"]\n[Date "2024.05.01"]\n'
    '[Result "$result"]\n\n$moves $result';

/// The position at the end of [moves].
Fen after(String moves) {
  final tree = readGame('$moves *').tree!;
  return tree.fenAt(tree.endOfLineFrom(const NodePath.root()));
}

/// [plies] legal moves from the start that never come back to a position:
/// at each turn the first move, in the generator's order, to a position not
/// seen yet.
String wanderingMoves(int plies) {
  Position position = Chess.initial;
  String key(Position p) => p.fen.split(' ').take(4).join(' ');
  final seen = {key(position)};
  final text = StringBuffer();
  for (var ply = 0; ply < plies; ply++) {
    final move = [
      for (final MapEntry(key: from, value: targets)
          in position.legalMoves.entries)
        for (final to in targets.squares) NormalMove(from: from, to: to),
    ].firstWhere((move) => seen.add(key(position.play(move))));
    final (next, san) = position.makeSan(move);
    if (ply.isEven) text.write('${ply ~/ 2 + 1}. ');
    text.write('$san ');
    position = next;
  }
  return text.toString().trim();
}

Map<String, (int, int, int, int)> table(ExplorerAnswer answer) => {
  for (final move in answer.moves)
    move.uci: (move.white, move.draws, move.black, move.undecided),
};

void main() {
  test('each move from a position counts its games by how they ended, '
      'most played first', () {
    final index = OpeningIndex.of([
      game('1. e4 e5', '1-0'),
      game('1. e4 c5', '1/2-1/2'),
      game('1. e4 e6', '0-1'),
      game('1. d4 d5', '*'),
    ]);
    final start = index.answer(Fen.initial);
    expect(start.moves.map((m) => m.uci), ['e2e4', 'd2d4']);
    expect(table(start), {'e2e4': (1, 1, 1, 0), 'd2d4': (0, 0, 0, 1)});
    expect(
      start.moves.last.games,
      1,
      reason: 'an unfinished game still counts as played',
    );
    expect(table(index.answer(after('1. e4'))), {
      'e7e5': (1, 0, 0, 0),
      'c7c5': (0, 1, 0, 0),
      'e7e6': (0, 0, 1, 0),
    });
  });

  test('two move orders to one position meet there', () {
    final index = OpeningIndex.of([
      game('1. e4 e5 2. Nf3 Nc6', '1-0'),
      game('1. Nf3 e5 2. e4 Nf6', '0-1'),
    ]);
    final meeting = index.answer(after('1. e4 e5 2. Nf3'));
    expect(table(meeting), {'b8c6': (1, 0, 0, 0), 'g8f6': (0, 0, 1, 0)});
    expect(meeting.games.map((g) => g.id), ['0', '1']);
  });

  test('the games under a position are named by the ids given, in the '
      'order given, with their players and year', () {
    final index = OpeningIndex.of(
      [
        game('1. e4', '1-0', white: 'Carlsen, M', black: 'Nakamura, H'),
        game('1. e4', '0-1'),
      ],
      ids: ['lichess_aaaa1111', 'lichess_bbbb2222'],
    );
    final games = index.answer(Fen.initial).games;
    expect(games.map((g) => g.id), ['lichess_aaaa1111', 'lichess_bbbb2222']);
    expect(games.first.white, 'Carlsen, M');
    expect(games.first.result, '1-0');
    expect(games.first.year, 2024);
  });

  test('a filter narrows the counts without building again', () {
    final index = OpeningIndex.of([
      game('1. e4', '1-0'),
      game('1. e4', '0-1'),
      game('1. d4', '1-0'),
    ]);
    final kept = index.answer(Fen.initial, keeps: (game) => game != 1);
    expect(table(kept), {'e2e4': (1, 0, 0, 0), 'd2d4': (1, 0, 0, 0)});
    expect(kept.games.map((g) => g.id), ['0', '2']);
    final none = index.answer(Fen.initial, keeps: (_) => false);
    expect(none.isEmpty, isTrue);
  });

  test('a game that comes back to a position counts there once', () {
    final index = OpeningIndex.of([
      game('1. Nf3 Nf6 2. Ng1 Ng8 3. Nf3', '1/2-1/2'),
    ]);
    expect(table(index.answer(Fen.initial)), {'g1f3': (0, 1, 0, 0)});
  });

  test('a game from a set-up position is indexed from there', () {
    const start = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';
    final index = OpeningIndex.of([
      '[FEN "$start"]\n[SetUp "1"]\n[Result "1-0"]\n\n1. e4 Kd7 1-0',
    ]);
    expect(table(index.answer(const Fen(start))), {'e2e4': (1, 0, 0, 0)});
    expect(index.answer(Fen.initial).isEmpty, isTrue);
  });

  test('the main line is read to move 25, variations not at all', () {
    final index = OpeningIndex.of([game('1. e4 (1. d4 d5) e5 2. Nf3', '*')]);
    expect(index.answer(Fen.initial).moves.map((m) => m.uci), ['e2e4']);
    final long = game(wanderingMoves(indexedPlies + 10), '*');
    final tree = readGame(long).tree!;
    final deep = OpeningIndex.of([long]);
    Fen before(int ply) => tree.fenAt(NodePath.of(List.filled(ply, 0)));
    expect(deep.answer(before(indexedPlies - 1)).isEmpty, isFalse);
    expect(deep.answer(before(indexedPlies)).isEmpty, isTrue);
  });

  test('a text with no moves or no playable start is counted, not indexed', () {
    final index = OpeningIndex.of([
      game('1. e4', '1-0'),
      '[Event "Empty"]\n\n*',
      '[FEN "not a position"]\n[SetUp "1"]\n\n1. e4 *',
      'this is not PGN at all',
    ]);
    expect(index.gameCount, 4);
    expect(index.unread, 3);
    expect(table(index.answer(Fen.initial)), {'e2e4': (1, 0, 0, 0)});
  });

  test('progress is heard every so many games', () {
    final heard = <int>[];
    OpeningIndex.of(
      List.filled(OpeningIndex.progressEvery * 2 + 1, game('1. e4', '*')),
      onProgress: heard.add,
    );
    expect(heard, [OpeningIndex.progressEvery, OpeningIndex.progressEvery * 2]);
  });

  test('at most so many games are listed under a position', () {
    final index = OpeningIndex.of(
      List.filled(gamesListed + 5, game('1. e4', '1-0')),
    );
    final answer = index.answer(Fen.initial);
    expect(answer.moves.single.games, gamesListed + 5);
    expect(answer.games, hasLength(gamesListed));
  });
}
