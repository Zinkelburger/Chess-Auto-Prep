import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/study_controller.dart';
import 'package:chess_auto_prep/models/study_document.dart';

StudyController _studyWith(List<String> names) {
  final c = StudyController();
  // Replace the fresh document's single chapter with the named set.
  c.doc.chapters
    ..clear()
    ..addAll([for (final n in names) StudyChapter(name: n)]);
  return c;
}

List<String> _names(StudyController c) =>
    c.doc.chapters.map((ch) => ch.name).toList();

void main() {
  group('reorderChapter', () {
    test('moves a chapter down', () {
      final c = _studyWith(['A', 'B', 'C']);
      c.reorderChapter(0, 2);
      expect(_names(c), ['B', 'C', 'A']);
    });

    test('moves a chapter up', () {
      final c = _studyWith(['A', 'B', 'C']);
      c.reorderChapter(2, 0);
      expect(_names(c), ['C', 'A', 'B']);
    });

    test('keeps the open chapter selected when other chapters move', () {
      final c = _studyWith(['A', 'B', 'C']);
      c.selectChapter(1); // viewing B
      c.reorderChapter(2, 0); // C jumps to the front
      expect(_names(c), ['C', 'A', 'B']);
      expect(c.chapter.name, 'B');
      expect(c.chapterIndex, 2);
    });

    test('keeps the open chapter selected when it is the one moved', () {
      final c = _studyWith(['A', 'B', 'C']);
      c.selectChapter(0);
      c.reorderChapter(0, 2);
      expect(c.chapter.name, 'A');
      expect(c.chapterIndex, 2);
    });

    test('ignores no-op and out-of-range moves', () {
      final c = _studyWith(['A', 'B']);
      c.reorderChapter(0, 0);
      c.reorderChapter(-1, 1);
      c.reorderChapter(5, 0);
      expect(_names(c), ['A', 'B']);
    });
  });
}
