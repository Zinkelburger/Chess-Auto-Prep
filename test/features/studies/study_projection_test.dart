import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/study_fixture.dart';

void main() {
  test('sibling promotion and deletion preserve the viewed line', () {
    final study = memoryStudy();
    addTearDown(study.dispose);
    for (final san in ['e4', 'd4', 'c4']) {
      study.goToStart();
      study.playSan(san);
    }
    study.jump(const TreePath([0]));
    study.promote(const TreePath([1]));
    expect(study.tree.sanSequenceAt(study.path), ['e4']);
    study.deleteAt(const TreePath([0]));
    expect(study.tree.sanSequenceAt(study.path), ['e4']);
    expect(study.doc.toPgn(), study.captureWorkspace().content);
  });

  test('deleting another chapter preserves the active chapter and cursor', () {
    final study = memoryStudy();
    addTearDown(study.dispose);
    study.addChapter('Active');
    study.playSan('d4');
    final active = study.chapter;
    study.deleteChapter(0);
    expect(study.chapter, same(active));
    expect(study.chapterIndex, 0);
    expect(study.tree.sanSequenceAt(study.path), ['d4']);
  });

  test(
    'incremental projections reconcile batched branch edits by node identity',
    () {
      final study = memoryStudy();
      addTearDown(study.dispose);
      study.playSan('e4');
      study.playSan('e5');
      study.goToStart();
      study.playSan('d4');
      study.playSan('d5');
      final before = study.doc;
      final unchanged = study.tree.roots.first;
      study.setComment(study.path, 'Queen pawn');
      expect(study.tree.roots.first, same(unchanged));
      for (var i = 0; i < 30; i++) {
        // Several edits precede one projection read. Reordering must not apply
        // earlier invalidation paths to the wrong sibling.
        study.setComment(const TreePath([1, 0]), 'batch $i');
        study.promote(const TreePath([1]));
        study.toggleNag(const TreePath([0, 0]), 1);
        study.goToStart();
        study.playSan('c4');
        study.playSan('e5');
        study.deleteAt(const TreePath([2]));
        expect(study.doc.toPgn(), study.captureWorkspace().content);
      }
      expect(before.toPgn(), isNot(contains('batch')));
      study.clearChapterAnnotations(0);
      study.setComment(const TreePath([0]), 'after bulk edit');
      expect(study.doc.toPgn(), study.captureWorkspace().content);
      study.clearChapterVariations(0);
      expect(study.doc.toPgn(), study.captureWorkspace().content);
    },
  );

  test(
    'old projections retain all values after edits and structural changes',
    () {
      final study = memoryStudy();
      addTearDown(study.dispose);
      study.playSan('e4');
      study.setComment(study.path, 'original');
      study.toggleNag(study.path, 1);
      study.updateChapter(0, headers: {'ECO': 'B00'});
      final before = study.doc;
      final pgn = before.toPgn();
      final chapter = before.chapters.single;
      final node = chapter.tree.roots.single;

      study.setComment(study.path, 'changed');
      study.toggleNag(study.path, 2);
      study.updateChapter(0, name: 'Renamed', headers: {'ECO': 'C00'});
      study.playSan('e5');
      expect(before.toPgn(), pgn);
      expect(node.comment, 'original');
      expect(node.nags, [1]);
      expect(node.children, isEmpty);
      expect(chapter.headers, {'ECO': 'B00'});
      expect(study.doc, isNot(before));
      expect(study.doc.session, before.session);
      expect(study.chapter.key, chapter.key);
      expect(() => before.chapters.clear(), throwsUnsupportedError);
      expect(() => chapter.headers.clear(), throwsUnsupportedError);
      expect(() => chapter.tree.roots.clear(), throwsUnsupportedError);
      expect(() => node.children.clear(), throwsUnsupportedError);
      expect(() => node.nags!.clear(), throwsUnsupportedError);

      study.deleteAt(const TreePath([0]));
      expect(before.toPgn(), pgn);
      expect(study.tree.isEmpty, isTrue);
    },
  );

  test('navigation and unrelated chapters reuse immutable projections', () {
    final study = memoryStudy();
    addTearDown(study.dispose);
    study.playSan('e4');
    final first = study.chapter;
    study.addChapter('Second');
    study.playSan('d4');
    final document = study.doc;
    final second = study.chapter;
    for (var i = 0; i < 200; i++) {
      study.goToStart();
      study.goForward();
      study.toggleFlipped();
      expect(study.doc, same(document));
      expect(study.tree, same(second.tree));
    }
    study.setComment(study.path, 'Only the second chapter changes');
    expect(study.doc.chapters.first, same(first));
    expect(study.chapter, isNot(second));
    study.reorderChapter(1, 0);
    expect(study.doc.chapters.last, same(first));
    expect(study.chapter.name, 'Second');
    expect(first, isNot(second));
    expect(first, isNot(document));
  });

  test(
    'navigation and no-op annotations do not create edits or notifications',
    () async {
      final study = memoryStudy();
      addTearDown(study.dispose);
      await study.importChapters('1. e4 e5 *');
      await study.saveCopy('/navigation.pgn');
      final before = study.doc;
      final closeRevision = study.closeRevision;
      var notifications = 0;
      study.addListener(() => notifications++);
      study.jump(TreePath.empty);
      study.setComment(const TreePath([999]), 'invalid');
      study.setComment(TreePath.empty, null);
      expect(notifications, 0);
      study.playSan('e4');
      expect(notifications, 1);
      expect(study.dirty, isFalse);
      expect(study.closeRevision, closeRevision);
      expect(study.doc, same(before));
    },
  );

  test('a caller-owned path cannot mutate the controller cursor', () {
    final study = memoryStudy();
    addTearDown(study.dispose);
    study.playSan('e4');
    final indices = [0];
    study.goToStart();
    study.jump(TreePath(indices));
    indices[0] = 999;
    expect(study.path, const TreePath([0]));
    expect(study.path.indices, isNot(isA<List<int>>()));
  });

  test(
    'replacing a document changes session identity even at equal revisions',
    () async {
      final study = memoryStudy();
      addTearDown(study.dispose);
      final first = study.doc;
      await study.newStudy('Second');
      expect(study.doc.session, isNot(first.session));
      expect(study.chapter.session, study.doc.session);
      expect(study.doc, isNot(first));
      expect(first.name, 'Untitled study');
    },
  );
}
