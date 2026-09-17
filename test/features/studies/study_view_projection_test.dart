import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_projection_cache.dart';
import 'package:chess_auto_prep/features/studies/models/study_document.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/study_fixture.dart';

class _ObservedTree extends MoveTree {
  int reads = 0;
  @override
  List<MoveNode> get roots {
    reads++;
    return super.roots;
  }
}

void main() {
  test('a 20000-node course materializes only the selected chapter', () {
    final trees = <_ObservedTree>[];
    for (var chapter = 0; chapter < 100; chapter++) {
      final tree = _ObservedTree();
      var children = tree.roots;
      for (var ply = 0; ply < 200; ply++) {
        final node = MoveNode(san: 'Nf3', fen: kStandardStartFen);
        children.add(node);
        children = node.children;
      }
      tree.reads = 0;
      trees.add(tree);
    }
    final document = StudyDocument(
      name: 'Course',
      chapters: [
        for (var i = 0; i < trees.length; i++)
          StudyChapter(name: 'Chapter $i', tree: trees[i]),
      ],
    );
    final cache = StudyProjectionCache();
    final watch = Stopwatch()..start();
    final metadata = cache.readChapterList(document, 0);
    final metadataMicros = watch.elapsedMicroseconds;
    expect(trees.every((tree) => tree.reads == 0), isTrue);
    watch.reset();
    final selected = cache.readChapter(document, document.chapters[50]);
    final chapterMicros = watch.elapsedMicroseconds;
    watch.stop();
    expect(selected.name, 'Chapter 50');
    expect(trees[50].reads, greaterThan(0));
    expect([
      for (var i = 0; i < trees.length; i++)
        if (i != 50) trees[i].reads,
    ], everyElement(0));
    expect(() => metadata.chapters.clear(), throwsUnsupportedError);
    // Diagnostic only; correctness does not depend on this host's clock speed.
    // ignore: avoid_print
    print(
      '20000-node course: metadata $metadataMicros us; selected 200-node chapter $chapterMicros us',
    );
  });

  test('chapter metadata and identity do not materialize any move tree', () {
    final first = _ObservedTree();
    final second = _ObservedTree();
    final document = StudyDocument(
      name: 'Large course',
      chapters: [
        StudyChapter(name: 'First', tree: first),
        StudyChapter(name: 'Second', tree: second),
      ],
    );
    final cache = StudyProjectionCache();
    final metadata = cache.readChapterList(document, 0);
    expect(cache.sessionFor(document), metadata.session);
    expect(first.reads, 0);
    expect(second.reads, 0);
    final chapter = cache.readChapter(document, document.chapters.first);
    expect(chapter.key, metadata.chapters.first.key);
    expect(first.reads, greaterThan(0));
    expect(second.reads, 0);
    for (var i = 0; i < 200; i++) {
      expect(cache.readChapterList(document, 0), same(metadata));
    }
    expect(second.reads, 0);
  });

  test('metadata reads do not consume another chapter pending edit', () {
    final document = StudyDocument(
      name: 'Study',
      chapters: [
        StudyChapter(name: 'First', tree: MoveTree.fromMoves(['e4', 'e5'])),
        StudyChapter(name: 'Second', tree: MoveTree.fromMoves(['d4', 'd5'])),
      ],
    );
    final cache = StudyProjectionCache();
    final before = cache.read(document, 0);
    final metadata = cache.readChapterList(document, 0);
    final chapter = document.chapters.last;
    chapter.tree.setComment(const TreePath([0, 0]), 'pending');
    cache.changed(chapter, path: const TreePath([0, 0]));
    expect(cache.readChapterList(document, 1), same(metadata));
    expect(
      cache.readChapter(document, document.chapters.first),
      same(before.chapters.first),
    );
    expect(
      cache
          .readChapter(document, chapter)
          .tree
          .commentAt(const TreePath([0, 0])),
      'pending',
    );
    expect(cache.read(document, 1).toPgn(), document.toPgn());
    expect(before.toPgn(), isNot(contains('pending')));
  });

  test(
    'cursor revisions are independent of unrelated document and save updates',
    () async {
      final study = memoryStudy();
      addTearDown(study.dispose);
      study.playSan('e4');
      study.playSan('e5');
      study.goToStart();
      final before = study.cursor;
      final metadata = study.chapterList;
      study.setComment(const TreePath([0, 0]), 'elsewhere');
      expect(study.cursor, same(before));
      expect(study.chapterList, same(metadata));
      study.updateChapter(0, name: 'New name');
      expect(study.cursor, same(before));
      expect(study.chapterList, isNot(metadata));
      await study.saveCopy('/copy.pgn');
      expect(study.cursor, same(before));
      study.goForward();
      final move = study.cursor;
      expect(move, isNot(before));
      expect(before.path, TreePath.empty);
      expect(move.path, const TreePath([0]));
      study.toggleNag(study.path, 1);
      expect(study.cursor.nags, [1]);
      expect(move.nags, isEmpty);
      expect(() => study.cursor.nags.clear(), throwsUnsupportedError);
      final annotated = study.cursor;
      study.toggleFlipped();
      expect(study.cursor, isNot(annotated));
      expect(annotated.flipped, isFalse);
    },
  );

  test(
    'chapter action snapshots follow reorder but reject intervening edits',
    () {
      final study = memoryStudy();
      addTearDown(study.dispose);
      final first = study.chapter;
      study.addChapter('Second');
      study.reorderChapter(0, 1);
      expect(study.indexOfChapter(first), 1);
      study.updateChapter(1, name: 'Revised');
      expect(study.indexOfChapter(first), -1);
      expect(first.name, 'Chapter 1');
    },
  );
}
