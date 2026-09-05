/// Chapter-level behaviour of [StudyController] that needs no file: the
/// board faces each chapter's orientation, "Flip board" is for this sitting
/// only, and the chapter tools edit what they say they edit.
library;

import 'package:chess_auto_prep/core/study_controller.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/models/study_document.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

StudyController _study() {
  final c = StudyController();
  c.doc.chapters
    ..clear()
    ..addAll([
      StudyChapter(name: 'White chapter', orientation: Side.white),
      StudyChapter(name: 'Black chapter', orientation: Side.black),
    ]);
  c.selectChapter(0);
  return c;
}

void main() {
  group('orientation', () {
    test('the board faces the chapter that opens', () {
      final c = _study();
      expect(c.flipped, isFalse);
      c.selectChapter(1);
      expect(c.flipped, isTrue);
      c.selectChapter(0);
      expect(c.flipped, isFalse);
    });

    test('flipping is for this sitting; the next chapter resets it', () {
      final c = _study();
      c.toggleFlipped();
      expect(c.flipped, isTrue);
      expect(c.chapter.orientation, Side.white, reason: 'nothing saved');
      c.selectChapter(1);
      c.selectChapter(0);
      expect(c.flipped, isFalse);
    });

    test('editing the open chapter turns the board at once', () {
      final c = _study();
      c.updateChapter(0, orientation: Side.black);
      expect(c.chapter.orientation, Side.black);
      expect(c.flipped, isTrue);
    });

    test('a new chapter faces the side it was created for', () {
      final c = _study();
      c.addChapter('', orientation: Side.black);
      expect(c.chapter.name, 'Chapter 3');
      expect(c.flipped, isTrue);
    });
  });

  group('updateChapter', () {
    test(
      'renames, and replaces the loose tags without touching owned ones',
      () {
        final c = _study();
        c.updateChapter(
          0,
          name: '  Renamed  ',
          headers: {'ECO': 'C50', 'ChapterName': 'ignored', '': 'ignored'},
        );
        expect(c.chapter.name, 'Renamed');
        expect(c.chapter.headers, {'ECO': 'C50'});
        expect(c.dirty, isTrue);
      },
    );

    test('a blank name keeps the old one', () {
      final c = _study();
      c.updateChapter(0, name: '   ');
      expect(c.chapter.name, 'White chapter');
    });
  });

  group('chapter tools', () {
    test('clearChapterVariations keeps the cursor on a surviving move', () {
      final c = _study();
      c.playSan('e4');
      c.playSan('e5');
      c.goBack();
      c.playSan('c5'); // sideline 1... c5
      c.playSan('Nf3');
      expect(c.path, const TreePath([0, 1, 0]));
      c.clearChapterVariations(0);
      expect(c.tree.roots.single.children, hasLength(1));
      expect(c.tree.roots.single.children.single.san, 'e5');
      // The cursor was on the deleted sideline: it retreats to 1. e4.
      expect(c.path, const TreePath([0]));
    });

    test('clearChapterAnnotations empties the introduction too', () {
      final c = _study();
      c.setComment(TreePath.empty, 'Intro [%cal Ge2e4]');
      c.playSan('e4');
      c.setComment(c.path, 'Best by test');
      c.toggleNag(c.path, 1);
      c.clearChapterAnnotations(0);
      expect(c.cursorComment, isNull);
      expect(c.tree.rootComment, isNull);
      expect(c.tree.roots.single.nags, isNull);
    });

    test('a comment at the start position is the chapter introduction', () {
      final c = _study();
      expect(c.cursorComment, isNull);
      c.setComment(TreePath.empty, 'Read this first');
      expect(c.cursorComment, 'Read this first');
      expect(c.chapterPgn(0), contains('{Read this first}'));
    });
  });

  group('importChapters naming', () {
    test('a given name names one game and numbers several', () async {
      final c = _study();
      const two = '[Event "A"]\n\n1. e4 *\n\n[Event "B"]\n\n1. d4 *\n';
      await c.importChapters('1. c4 *', name: 'English');
      expect(c.chapter.name, 'English');
      await c.importChapters(two, name: 'Pair');
      expect(c.doc.chapters.map((ch) => ch.name).skip(3), ['Pair 1', 'Pair 2']);
    });

    test('without a name the PGN tags decide, study prefix stripped', () async {
      final c = _study();
      c.doc.name = 'Repertoire';
      await c.importChapters(
        '[Event "Repertoire: Najdorf"]\n\n1. e4 c5 *\n',
        orientation: Side.black,
      );
      expect(c.chapter.name, 'Najdorf');
      expect(c.chapter.orientation, Side.black);
      expect(c.flipped, isTrue);
    });
  });
}
