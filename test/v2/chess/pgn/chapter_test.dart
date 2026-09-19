import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  final chapter = parseChapter(name: 'Main', text: blackChapter);

  test('reads the side from the // Color line and counts the games', () {
    expect(chapter.side, Side.black);
    expect(chapter.gameCount, 2);
    expect(chapter.skippedGames, 1);
    expect(chapter.issues, isEmpty);
  });

  test('merges every game into one tree; the first game is the main line', () {
    final c5 = chapter.tree.children.single;
    expect(c5.san, 'c5');
    expect(c5.comment, 'The Sicilian [%eval 0.30]');
    expect(c5.children.map((n) => n.san), ['Nf3', 'Nc3']);

    final nf3 = c5.children[0];
    expect(nf3.children.map((n) => n.san), ['d6', 'Nc6']);
    expect(chapter.tree.nodeAt(NodePath.of([0, 1]))?.comment, 'Closed');
  });

  test('a file with no games is an empty White chapter', () {
    final empty = parseChapter(name: 'New', text: '// Main\n');
    expect(empty.side, Side.white);
    expect(empty.tree.isEmpty, isTrue);
    expect(empty.gameCount, 0);
  });
}
