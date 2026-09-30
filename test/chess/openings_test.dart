import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/openings.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:dartchess/dartchess.dart' show Chess, Position;
import 'package:flutter_test/flutter_test.dart';

const _volume =
    'eco\tname\tpgn\n'
    'B20\tSicilian Defense\t1. e4 c5\n'
    'B90\tSicilian Defense: Najdorf Variation\t'
    '1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6\n'
    '\n'
    'B99\tBroken row\t1. e4 c5 2. Ke3\n'
    'short row\n'
    'C00\tFrench Defense\t1. e4 e6\n';

/// The position after [sans] from the start.
Fen _after(String sans) {
  Position position = Chess.initial;
  for (final san in sans.split(' ')) {
    position = position.play(position.parseSan(san)!);
  }
  return Fen(position.fen);
}

void main() {
  final book = Openings.parse([_volume]);

  test('names a position by the row that reaches it', () {
    expect(book.at(_after('e4 c5')), const Opening('B20', 'Sicilian Defense'));
    expect(book.at(_after('e4 c5'))!.label, 'B20 Sicilian Defense');
    expect(book.at(_after('e4 e5')), isNull);
  });

  test('a transposition finds the same name, whatever the move counters', () {
    final najdorf = book.at(_after('Nf3 c5 e4 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6'));
    expect(najdorf?.eco, 'B90');
  });

  test('rows that do not replay or are short are skipped, not fatal', () {
    expect(book.at(_after('e4 e6'))?.name, 'French Defense');
    expect(book.at(_after('e4 c5 Ke2')), isNull);
  });

  test('the deepest named position of a line is the one it is in', () {
    final line = [
      Fen.initial,
      _after('e4'),
      _after('e4 c5'),
      _after('e4 c5 Nc3'),
    ];
    expect(book.deepestIn(line)?.eco, 'B20');
    expect(book.deepestIn([Fen.initial]), isNull);
  });

  test('along a tree: the path to the cursor and the main line', () {
    final tree = parseChapter(
      name: 'Najdorf',
      text:
          '[Event "?"]\n\n1. e4 c5 (1... e6 2. d4) 2. Nf3 d6 3. d4 cxd4 '
          '4. Nxd4 Nf6 5. Nc3 a6 6. Be2 *\n',
    ).tree;
    expect(book.ofMainLine(tree)?.eco, 'B90');
    expect(book.alongPath(tree, NodePath.of([0, 0]))?.eco, 'B20');
    expect(
      book.alongPath(tree, NodePath.of([0, 1, 0]))?.name,
      'French Defense',
    );
    expect(book.alongPath(tree, const NodePath.root()), isNull);
  });

  test('the bundled book replays: every volume names its openings', () {
    final bundled = Openings.parse([
      for (final volume in ['a', 'b', 'c', 'd', 'e'])
        File('assets/data/openings/$volume.tsv').readAsStringSync(),
    ]);
    expect(
      bundled.at(_after('e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6'))?.label,
      'B90 Sicilian Defense: Najdorf Variation',
    );
    expect(bundled.at(_after('d4 d5 c4'))?.eco, 'D06');
    expect(bundled.at(_after('Nh3'))?.eco, 'A00');
  });

  test('none names nothing', () {
    expect(Openings.none.isEmpty, isTrue);
    expect(Openings.none.at(_after('e4 c5')), isNull);
  });

  test('the opening line names the position, then a game by its tags, then '
      'by its main line; a merged chapter only by the position', () async {
    Future<Chapter> read(String text, {int? game}) =>
        readChapter(name: 'Main', text: text, game: game);

    const tagged =
        '[Event "E"]\n[ECO "B90"]\n[Opening "Sicilian"]\n[Result "*"]\n\n'
        '1. d4 d5 *\n';
    const plain = '[Event "E"]\n[Result "*"]\n\n1. e4 e6 2. d4 *\n';
    final game = await read(tagged, game: 0);
    expect(openingLine(book, game, const NodePath.root()), 'B90 Sicilian');
    final untagged = await read(plain, game: 0);
    expect(
      openingLine(book, untagged, const NodePath.root()),
      'C00 French Defense',
    );
    expect(
      openingLine(book, untagged, const NodePath.root(), answerHidden: true),
      '',
    );
    expect(
      openingLine(book, untagged, NodePath.of([0, 0])),
      'C00 French Defense',
    );
    final merged = await read(plain);
    expect(openingLine(book, merged, const NodePath.root()), '');
  });
}
