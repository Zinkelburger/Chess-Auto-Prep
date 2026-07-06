import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/models/study_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('single-chapter round-trip', () {
    test('moves, variations, and comments survive', () {
      const pgn = '''
[Event "Italian ideas"]
[White "?"]
[Black "?"]
[Result "*"]

1. e4 e5 2. Nf3 {Develop with tempo} Nc6 3. Bc4 (3. Bb5 a6 {The Morphy
Defence} 4. Ba4) 3... Bc5 *
''';
      final doc = StudyDocument.fromPgn(pgn, name: 'test');
      expect(doc.chapters, hasLength(1));
      final chapter = doc.chapters.single;
      expect(chapter.name, 'Italian ideas');

      final reparsed =
          StudyDocument.fromPgn(doc.toPgn(), name: 'test again');
      final tree = reparsed.chapters.single.tree;

      // Mainline: e4 e5 Nf3 Nc6 Bc4 Bc5
      expect(tree.sanSequenceAt(const TreePath([0, 0, 0, 0, 0, 0])),
          ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5']);
      // Comment survived.
      expect(tree.nodeAt(const TreePath([0, 0, 0]))?.comment,
          'Develop with tempo');
      // Variation 3. Bb5 with nested comment.
      final bb5 = tree.nodeAt(const TreePath([0, 0, 0, 0, 1]));
      expect(bb5?.san, 'Bb5');
      expect(bb5?.children.first.san, 'a6');
      expect(bb5?.children.first.comment, contains('Morphy'));
    });

    test('unknown headers are preserved', () {
      const pgn = '''
[Event "Ch 1"]
[Annotator "Coach"]
[ECO "C50"]
[Result "1-0"]

1. e4 1-0
''';
      final doc = StudyDocument.fromPgn(pgn, name: 't');
      final out = doc.toPgn();
      expect(out, contains('[Annotator "Coach"]'));
      expect(out, contains('[ECO "C50"]'));
      expect(out, contains('[Result "1-0"]'));
      expect(out.trim(), endsWith('1-0'));
    });
  });

  group('multi-chapter round-trip', () {
    test('chapters keep order, names, and custom start positions', () {
      final doc = StudyDocument.fresh('endgames');
      doc.chapters.single.name = 'Lucena';
      doc.chapters.single.tree.startingFen =
          '1k1K4/1P6/8/8/8/8/r7/2R5 w - - 0 1';
      doc.chapters.single.tree
          .addMove(TreePath.empty, 'Rc4'); // building the bridge
      doc.chapters.add(StudyChapter(name: 'Philidor'));
      doc.chapters[1].tree.addMove(TreePath.empty, 'e4');

      final reparsed = StudyDocument.fromPgn(doc.toPgn(), name: 'endgames');
      expect(reparsed.chapters, hasLength(2));
      expect(reparsed.chapters[0].name, 'Lucena');
      expect(reparsed.chapters[1].name, 'Philidor');
      expect(reparsed.chapters[0].tree.startingFen,
          '1k1K4/1P6/8/8/8/8/r7/2R5 w - - 0 1');
      expect(reparsed.chapters[0].tree.roots.single.san, 'Rc4');
      expect(reparsed.chapters[1].tree.startingFen, kStandardStartFen);
      expect(reparsed.chapters[1].tree.roots.single.san, 'e4');
    });

    test('empty chapter round-trips as an empty tree', () {
      final doc = StudyDocument.fresh('blank');
      final reparsed = StudyDocument.fromPgn(doc.toPgn(), name: 'blank');
      expect(reparsed.chapters.single.tree.isEmpty, isTrue);
      expect(reparsed.chapters.single.name, 'Chapter 1');
    });

    test('a second round-trip is byte-identical (stable serialization)', () {
      const pgn = '''
[Event "A"]

1. d4 d5 (1... Nf6 2. c4 {Indian structures}) 2. c4 *

[Event "B"]
[FEN "4k3/8/8/8/8/8/8/4K2R w K - 0 1"]
[SetUp "1"]

1. O-O *
''';
      final once = StudyDocument.fromPgn(pgn, name: 'x').toPgn();
      final twice = StudyDocument.fromPgn(once, name: 'x').toPgn();
      expect(twice, once);
    });

    test('parsing garbage yields a usable empty study', () {
      final doc = StudyDocument.fromPgn('not a pgn at all', name: 'junk');
      expect(doc.chapters, isNotEmpty);
    });
  });
}
