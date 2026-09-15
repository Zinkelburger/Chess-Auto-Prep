import 'package:chess_auto_prep/features/games/services/book_move_keys.dart';
import 'package:chess_auto_prep/features/games/services/repertoire_book_tree.dart';
import 'package:dartchess/dartchess.dart' show Chess;
import 'package:flutter_test/flutter_test.dart';

/// The chapter-to-positions reader behind the deviation walker: every path
/// is played out, positions are shared across move orders, and the author's
/// own-side brackets are commentary rather than book.
void main() {
  BookNode? nodeAfter(BookTree tree, List<String> sans) =>
      tree.nodeAt(positionKeysFromStart(sans).last);

  test('an empty or unparseable chapter is an empty tree', () {
    final tree = BookTree.fromChapter(
      '',
      ourSideWhite: true,
      chapterName: 'Main',
    );
    expect(tree.isEmpty, isTrue);
    expect(tree.nodeAt(positionKey(Chess.initial)), same(tree.root));
  });

  test('keys every position of every path, shared across move orders', () {
    final tree = BookTree.fromChapter(
      '''
// Color: White

[Event "English"]
[Result "*"]

1. c4 c5 2. Nf3 Nc6 *

[Event "Reti order"]
[Result "*"]

1. Nf3 c5 2. c4 Nc6 3. d4 *
''',
      ourSideWhite: true,
      chapterName: 'Main',
    );
    expect(tree.isEmpty, isFalse);
    final direct = nodeAfter(tree, ['c4', 'c5', 'Nf3']);
    final transposed = nodeAfter(tree, ['Nf3', 'c5', 'c4']);
    expect(direct, isNotNull);
    expect(direct, same(transposed), reason: 'one position, one node');
    // The first order that reached it names the path.
    expect(direct!.path, ['c4', 'c5', 'Nf3']);
    // Both continuations are known from that one node.
    expect(nodeAfter(tree, ['c4', 'c5', 'Nf3', 'Nc6'])!.display.values, ['d4']);
  });

  test('a variation in brackets is part of the book', () {
    final tree = BookTree.fromChapter(
      '''
// Color: White

[Event "Open"]
[Result "*"]

1. e4 e5 (1... c5 2. Nf3) 2. Nf3 *
''',
      ourSideWhite: true,
      chapterName: 'Main',
    );
    expect(nodeAfter(tree, ['e4', 'c5', 'Nf3']), isNotNull);
    expect(tree.root.children.values.single.display.values, ['e5', 'c5']);
  });

  test('a bracket at our own move is commentary, not book', () {
    final tree = BookTree.fromChapter(
      '''
// Color: White

[Event "Caro"]
[Result "*"]

1. e4 c6 2. d4 d5 3. Nc3 (3. e5 Bf5) dxe4 *
''',
      ourSideWhite: true,
      chapterName: 'Main',
    );
    final beforeThird = nodeAfter(tree, ['e4', 'c6', 'd4', 'd5'])!;
    expect(beforeThird.display.values, ['Nc3']);
    expect(beforeThird.alternatives.values, ['e5']);
    expect(
      nodeAfter(tree, ['e4', 'c6', 'd4', 'd5', 'e5']),
      isNull,
      reason: 'the mentioned move is not followed',
    );
  });

  test('read for the other side, the same bracket is coverage', () {
    final tree = BookTree.fromChapter(
      '''
// Color: Black

[Event "Caro"]
[Result "*"]

1. e4 c6 2. d4 d5 3. Nc3 (3. e5 Bf5) dxe4 *
''',
      ourSideWhite: false,
      chapterName: 'Main',
    );
    final beforeThird = nodeAfter(tree, ['e4', 'c6', 'd4', 'd5'])!;
    expect(beforeThird.display.values, ['Nc3', 'e5']);
    expect(beforeThird.alternatives, isEmpty);
    expect(nodeAfter(tree, ['e4', 'c6', 'd4', 'd5', 'e5', 'Bf5']), isNotNull);
  });

  test('a model game and a custom-start line are not the book', () {
    final tree = BookTree.fromChapter(
      '''
// Color: White

[Event "Line"]
[Result "*"]

1. d4 d5 *

[Event "Line"]
[White "Model games"]
[Black "Carlsen, M – Nakamura, H"]
[Result "*"]
[ModelGameWhite "Carlsen, M"]
[ModelGameBlack "Nakamura, H"]
[ModelGameResult "1-0"]

1. d4 d5 2. c4 e6 3. Nc3 *

[Event "From a position"]
[FEN "rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 2"]
[SetUp "1"]
[Result "*"]

2. c4 *
''',
      ourSideWhite: true,
      chapterName: 'Main',
    );
    expect(nodeAfter(tree, ['d4', 'd5']), isNotNull);
    expect(nodeAfter(tree, ['d4', 'd5', 'c4']), isNull);
  });

  test('an illegal move ends its branch, not the chapter', () {
    final tree = BookTree.fromChapter(
      '''
// Color: White

[Event "Broken"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O *
''',
      ourSideWhite: true,
      chapterName: 'Main',
    );
    // Break the line by hand: a bishop that cannot go there.
    final broken = BookTree.fromChapter(
      '''
// Color: White

[Event "Broken"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Bh6 Nf6 *

[Event "Other"]
[Result "*"]

1. d4 d5 *
''',
      ourSideWhite: true,
      chapterName: 'Main',
    );
    expect(nodeAfter(tree, ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6']), isNotNull);
    expect(
      nodeAfter(broken, ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6'])!.hasMoves,
      isFalse,
    );
    expect(nodeAfter(broken, ['d4', 'd5']), isNotNull);
  });

  test('a position is named by a real line over an introduction', () {
    final tree = BookTree.fromChapter(
      '''
// Color: White

[Event "Sicilian"]
[White "Introduction"]
[Black "Introduction"]
[Result "*"]

1. e4 c5 2. Nf3 *

[Event "Sicilian"]
[White "3) Najdorf"]
[Black "6.Bg5 main line"]
[Result "*"]

1. e4 c5 2. Nf3 d6 3. d4 *

[Event "Sicilian"]
[White "3) Najdorf"]
[Black "6.Bg5 with 6...Nbd7"]
[Result "*"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 *
''',
      ourSideWhite: true,
      chapterName: 'Main',
    );
    final shared = nodeAfter(tree, ['e4', 'c5'])!;
    expect(isNonRepertoireTitle('Introduction'), isTrue);
    expect(shared.lineName, isNotNull);
    expect(isNonRepertoireTitle(shared.lineName!), isFalse);
    expect(shared.lineName, '3) Najdorf › 6.Bg5 main line');
  });
}
