import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/comment_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/move_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_edit.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

String movesOf(Chapter chapter) => writeMoveText(chapter.tree, terminator: '*');

/// The chapter written out and read back, which is what the old app and the
/// next session see.
Chapter reread(Chapter chapter) =>
    parseChapter(name: chapter.name, text: writeChapter(chapter));

/// The chapter the move landed in; the cast fails the test when the move
/// was rejected.
Chapter added(Chapter chapter, NodePath at, String uci) =>
    (addMove(chapter, at: at, uci: uci) as MoveAdded).chapter;

/// The chapter the comment landed in; the cast fails the test when the
/// chapter refused the edit.
Chapter commented(
  Chapter chapter, {
  required NodePath at,
  required String? text,
}) => (setComment(chapter, at: at, text: text) as CommentWritten).chapter;

Chapter white() => parseChapter(name: 'Gambit', text: whiteChapter);

Chapter black() => parseChapter(name: 'Sicilian', text: blackChapter);

void main() {
  // 1. d4 d5 2. c4 c6 3. Nf3, the whole of the second game: a leaf.
  final leaf = NodePath.of([0, 0, 0, 1, 0]);
  final beforeLeaf = white();
  final afterLeaf = added(beforeLeaf, leaf, 'g8f6');

  test('a move at the end of a line extends exactly that game', () {
    expect(afterLeaf.lines[1].text, endsWith('3. Nf3 Nf6 *'));
    expect(afterLeaf.lines[1].text, contains('[CumProb "0.31"]'));
    expect(afterLeaf.lines, hasLength(3));
  });

  test('the games it did not touch keep their bytes and their ids', () {
    expect(afterLeaf.lines[0].text, beforeLeaf.lines[0].text);
    expect(afterLeaf.lines[2].text, beforeLeaf.lines[2].text);
    expect(
      afterLeaf.lines.map((line) => line.lineId),
      beforeLeaf.lines.map((line) => line.lineId),
    );
  });

  test('the edited file reads back as the tree the edit produced', () {
    expect(movesOf(reread(afterLeaf)), movesOf(afterLeaf));
    expect(
      addMove(beforeLeaf, at: leaf, uci: 'g8f6'),
      isA<MoveAdded>().having(
        (r) => r.path,
        'path',
        NodePath.of([0, 0, 0, 1, 0, 0]),
      ),
    );
  });

  // After 1. d4, which already has d5 and Nf6: a branch point.
  final beforeBranch = white();
  final afterBranch = added(beforeBranch, NodePath.of([0]), 'e7e6');
  final branchLine = afterBranch.lines.last;

  test('a move at a branch point writes a new game', () {
    expect(afterBranch.lines, hasLength(4));
    expect(branchLine.tags.whereType<PgnTag>().map((t) => t.key), [
      'Event',
      'White',
      'Black',
      'Result',
      'LineID',
    ]);
    expect(tagValue(branchLine.tags, 'White'), 'Me');
    expect(tagValue(branchLine.tags, 'Black'), 'Training');
    expect(tagValue(branchLine.tags, 'Result'), '*');
    expect(branchLine.text, endsWith('1. d4 e6 *'));
  });

  test('the new game is named after the game and move it branched on', () {
    expect(
      tagValue(branchLine.tags, 'Event'),
      "Queen's Gambit: Repertoire for White — 1...e6",
    );
  });

  test('the new game gets an id no other line in the file has', () {
    final ids = afterBranch.lines.map((line) => line.lineId).toList();
    expect(branchLine.lineId, isNotNull);
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids.take(3), beforeBranch.lines.map((line) => line.lineId));
  });

  test('the new game does not repeat the shared prefix comments', () {
    expect(branchLine.text, isNot(contains('Our repertoire')));
    expect(branchLine.text, isNot(contains('%eval')));
  });

  test('the new game reads back as the last variation', () {
    final d4 = reread(afterBranch).tree.children.single;
    expect(d4.children.map((n) => n.san), ['d5', 'Nf6', 'e6']);
    for (var i = 0; i < 3; i++) {
      expect(afterBranch.lines[i].text, beforeBranch.lines[i].text);
    }
  });

  final beforeFen = black();
  final afterFen = added(beforeFen, const NodePath.root(), 'e7e5');

  test('a new game in a FEN chapter carries the root as FEN and SetUp', () {
    final line = afterFen.lines.last;
    expect(
      tagValue(line.tags, 'FEN'),
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
    );
    expect(tagValue(line.tags, 'SetUp'), '1');
    expect(line.text, endsWith('1... e5 *'));
    expect(tagValue(line.tags, 'Event'), 'Test: Repertoire for Black — 1...e5');
  });

  test('a new game in a Black chapter names the sides the other way', () {
    expect(tagValue(afterFen.lines.last.tags, 'White'), 'Training');
    expect(tagValue(afterFen.lines.last.tags, 'Black'), 'Me');
    expect(afterFen.lines[2].text, beforeFen.lines[2].text);
    expect(reread(afterFen).skippedGames, 1);
  });

  final afterFirst = added(
    parseChapter(name: 'Sidelines', text: emptyChapter),
    const NodePath.root(),
    'd2d4',
  );

  test('the first move of an empty chapter starts a game of its own', () {
    expect(writeChapter(afterFirst), startsWith('$emptyChapter\n[Event '));
    expect(writeChapter(afterFirst), endsWith('1. d4 *\n'));
    expect(tagValue(afterFirst.lines.single.tags, 'Event'), 'Repertoire Line');
    expect(
      afterFirst.lines.single.tags.whereType<PgnTag>().map((t) => t.key),
      isNot(contains('FEN')),
    );
  });

  test('a new move is the last child of the node it was played from', () {
    // 1. d4 already has d5 and Nf6, so e6 is a branch and a third child.
    final branched = addMove(white(), at: NodePath.of([0]), uci: 'e7e6');
    expect((branched as MoveAdded).path, NodePath.of([0, 2]));
    expect(branched.chapter.tree.nodeAt(NodePath.of([0, 2]))?.san, 'e6');
    // 1. d4 Nf6 is the end of its game, so Nf3 extends it as an only child.
    final extended = addMove(white(), at: NodePath.of([0, 1]), uci: 'g1f3');
    expect((extended as MoveAdded).path, NodePath.of([0, 1, 0]));
    expect(extended.chapter.tree.nodeAt(NodePath.of([0, 1, 0]))?.san, 'Nf3');
  });

  test('a move the chapter already has moves the cursor and nothing else', () {
    final before = black();
    final result = addMove(before, at: const NodePath.root(), uci: 'c7c5');
    expect(result, isA<MoveAdded>());
    expect((result as MoveAdded).path, NodePath.of([0]));
    expect(writeChapter(result.chapter), blackChapter);
  });

  group('a branch below a ply where nobody moved', () {
    final chapter = parseChapter(name: 'Waiting', text: nullMoveChapter);

    test('reads as two lines through the waiting ply', () {
      expect(mainlineSans(chapter.tree), ['--', 'e5', 'Nf3']);
      expect(chapter.gameCount, 2);
    });

    test('writes a game that holds the move that was played', () {
      final result = addMove(chapter, at: NodePath.of([0, 0]), uci: 'c2c4');
      expect(result, isA<MoveAdded>());
      final after = (result as MoveAdded).chapter;
      expect(after.lines, hasLength(3));
      expect(after.lines.last.text, contains('1. -- e5 2. c4 *'));
      expect(after.tree.nodeAt(result.path)?.san, 'c4');
    });

    test('leaves the games it branched from alone', () {
      final after = added(chapter, NodePath.of([0, 0]), 'c2c4');
      expect(after.lines[0].text, chapter.lines[0].text);
      expect(after.lines[1].text, chapter.lines[1].text);
    });

    test('reads back as the last variation of the waiting ply', () {
      final after = reread(added(chapter, NodePath.of([0, 0]), 'c2c4'));
      final e5 = after.tree.children.single.children.single;
      expect(e5.children.map((node) => node.san), ['Nf3', 'd4', 'c4']);
    });
  });

  test('a chapter that comes back without the move says so', () {
    // A tree claiming a move no game of it can replay: writing the branch
    // would give a game that does not hold the move the user just played,
    // and saying it did is the one answer that loses their work.
    const impossible = Chapter(
      name: 'Impossible',
      side: Side.white,
      preamble: '',
      lines: [],
      tree: GameTree(
        rootFen: Fen.initial,
        children: [MoveNode(san: 'Ke3', uci: 'e1e3', fen: Fen.initial)],
      ),
    );
    expect(
      addMove(impossible, at: NodePath.of([0]), uci: 'e2e4'),
      isA<MoveNotWritten>(),
    );
  });

  test('a move that cannot be played is reported, not written', () {
    final before = black();
    expect(
      addMove(before, at: NodePath.of([0]), uci: 'e7e5'),
      isA<MoveIllegal>().having((r) => r.uci, 'uci', 'e7e5'),
    );
    expect(
      addMove(before, at: const NodePath.root(), uci: 'zz99'),
      isA<MoveIllegal>(),
    );
    expect(writeChapter(before), blackChapter);
  });
}

/// Two lines through a ply where nobody moved, which Chessable writes as a
/// waiting move and every replay has to be able to play.
const nullMoveChapter = '''
// Color: White

[Event "A"]
[Result "*"]

1. Z0 e5 2. Nf3 *

[Event "B"]
[Result "*"]

1. Z0 e5 2. d4 *
''';
