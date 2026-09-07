import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/opponents/services/repertoire_check.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:flutter_test/flutter_test.dart';

/// The check answers one question: which of the opponent's moves does my
/// book not answer? Only *their* moves count, the first off-book move ends
/// the line, and "the book stops here" is reported apart from "the book
/// continues but not against this".
void main() {
  OpeningTreeNode node(
    String move,
    int games, [
    List<OpeningTreeNode> kids = const [],
  ]) {
    final n = OpeningTreeNode(
      move: move,
      fen: kStandardStartFen,
      gamesPlayed: games,
      wins: games,
    );
    for (final k in kids) {
      k.parent = n;
      n.children[k.move] = k;
    }
    return n;
  }

  /// Their games as Black: 20× 1.e4 c5 (10× 2.Nf3 d6, 6× 2.Nf3 Nc6, 4× 2.c3 d5),
  /// 5× 1.e4 e5 2.Nf3 Nc6 3.Bb5 a6.
  OpeningTree theirTree() {
    final root = node('', 25, [
      node('e4', 25, [
        node('c5', 20, [
          node('Nf3', 16, [node('d6', 10), node('Nc6', 6)]),
          node('c3', 4, [node('d5', 4)]),
        ]),
        node('e5', 5, [
          node('Nf3', 5, [
            node('Nc6', 5, [
              node('Bb5', 5, [node('a6', 5)]),
            ]),
          ]),
        ]),
      ]),
    ]);
    return OpeningTree(root: root);
  }

  test('lists unanswered moves and the end of the book, most played first', () {
    // My White book: 1.e4 c5 2.Nf3 d6 3.d4 and 1.e4 e5 2.Nf3 Nc6 3.Bb5.
    // Two chapters, as a repertoire file holds them.
    final book = BookTrie()
      ..addPgn(
        '[Event "Sicilian"]\n\n1. e4 c5 2. Nf3 d6 3. d4 *\n\n'
        '[Event "Spanish"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 *',
      );
    final report = RepertoireCheck.compare(
      tree: theirTree(),
      book: book,
      opponentIsWhite: false,
    );
    expect(report.totalGames, 25);
    expect(report.unanswered.map((g) => '${g.line} ×${g.games}'), [
      '1. e4 c5 2. Nf3 Nc6 ×6',
    ]);
    expect(report.pastTheEnd.map((g) => '${g.line} ×${g.games}'), [
      '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 ×5',
    ]);
    // 2.c3 is *my* move off the book: their reply says nothing about them.
    expect(report.gaps.any((g) => g.sans.contains('c3')), isFalse);
    expect(report.gapGames, 11);
  });

  test('check marks and castling spellings do not break a match', () {
    final book = BookTrie()..addPgn('1. e4 c5 2. Nf3 d6 *');
    final tree = OpeningTree(
      root: node('', 3, [
        node('e4', 3, [
          node('c5', 3, [
            node('Nf3+', 3, [node('d6!?', 3)]),
          ]),
        ]),
      ]),
    );
    final report = RepertoireCheck.compare(
      tree: tree,
      book: book,
      opponentIsWhite: false,
    );
    expect(report.gaps, isEmpty);
    expect(normalizeSan('0-0'), 'O-O');
    expect(normalizeSan('Qxf7#'), 'Qxf7');
  });

  test('an empty book yields no findings and hasBook is false', () {
    final report = RepertoireCheck.compare(
      tree: theirTree(),
      book: BookTrie(),
      opponentIsWhite: false,
      bookChapters: 0,
    );
    expect(report.hasBook, isFalse);
    expect(report.gaps, isEmpty);
  });
}
