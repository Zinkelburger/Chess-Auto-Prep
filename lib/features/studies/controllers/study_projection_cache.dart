import 'package:flutter/foundation.dart' show mapEquals;

import '../../../chess_core/moves/move_tree_projection_cache.dart';
import '../../../models/move_tree.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import '../models/study_document.dart';
import '../models/study_projection.dart';

/// Session-private projection builder. Only changed chapters are copied; save
/// status and cursor notifications return the exact existing document view.
class StudyProjectionCache {
  StudyDocument? _source;
  Object _session = Object();
  int _revision = 0;
  int? _editRevision;
  StudyDocumentProjection? _document;
  final _chapters = <StudyChapter, (MoveTree, StudyChapterProjection)>{};

  final _trees = <StudyChapter, MoveTreeProjectionCache>{};

  /// A previously requested whole-document view must not pin superseded trees
  /// while the UI now reads only the active chapter and lightweight metadata.
  void edited() => _document = null;

  void changed(StudyChapter chapter, {TreePath? path}) {
    _trees
        .putIfAbsent(chapter, MoveTreeProjectionCache.new)
        .changed(chapter.tree, path: path);
  }

  final _chapterKeys = <StudyChapter, Object>{};
  StudyChapterListProjection? _list;
  int? _listEditRevision;

  Object sessionFor(StudyDocument source) {
    if (!identical(source, _source)) {
      _source = source;
      _session = Object();
      _document = null;
      _list = null;
      _chapters.clear();
      _chapterKeys.clear();
      _trees.clear();
    }
    return _session;
  }

  Object chapterKey(StudyDocument source, StudyChapter chapter) {
    sessionFor(source);
    return _chapterKeys.putIfAbsent(chapter, Object.new);
  }

  StudyChapterProjection readChapter(
    StudyDocument source,
    StudyChapter chapter,
  ) {
    sessionFor(source);
    final cached = _chapters[chapter];
    final old = cached?.$2;
    final sameSource = cached != null && identical(cached.$1, chapter.tree);
    final sameTree = sameSource && old!.tree.version == chapter.tree.version;
    if (sameTree &&
        old.name == chapter.name &&
        old.orientation == chapter.orientation &&
        mapEquals(old.headers, chapter.headers)) {
      return old;
    }
    final tree = _trees
        .putIfAbsent(chapter, MoveTreeProjectionCache.new)
        .read(chapter.tree);
    final next = StudyChapterProjection(
      session: _session,
      key: chapterKey(source, chapter),
      revision: ++_revision,
      name: chapter.name,
      orientation: chapter.orientation,
      headers: chapter.headers,
      tree: tree,
    );
    _chapters[chapter] = (chapter.tree, next);
    return next;
  }

  /// Metadata access never constructs move snapshots, even on first open.
  StudyChapterListProjection readChapterList(
    StudyDocument source,
    int editRevision,
  ) {
    sessionFor(source);
    final old = _list;
    if (old != null && _listEditRevision == editRevision) return old;
    _listEditRevision = editRevision;
    final items = [
      for (final chapter in source.chapters)
        StudyChapterSummary(
          key: chapterKey(source, chapter),
          name: chapter.name,
          result: chapter.headers['Result'],
        ),
    ];
    if (old != null && old.chapters.length == items.length) {
      var same = true;
      for (var i = 0; i < items.length; i++) {
        if (items[i] != old.chapters[i]) {
          same = false;
          break;
        }
      }
      if (same) return old;
    }
    _prune(source);
    return _list = StudyChapterListProjection(
      session: _session,
      revision: ++_revision,
      chapters: items,
    );
  }

  void _prune(StudyDocument source) {
    final current = source.chapters.toSet();
    _chapters.removeWhere((chapter, _) => !current.contains(chapter));
    _chapterKeys.removeWhere((chapter, _) => !current.contains(chapter));
    _trees.removeWhere((chapter, _) => !current.contains(chapter));
  }

  StudyDocumentProjection read(StudyDocument source, int editRevision) {
    sessionFor(source);
    final previous = _document;
    if (previous != null &&
        _editRevision == editRevision &&
        previous.name == source.name &&
        previous.filePath == source.filePath) {
      return previous;
    }
    _editRevision = editRevision;
    _prune(source);
    final chapters = [
      for (final chapter in source.chapters) readChapter(source, chapter),
    ];
    return _document = StudyDocumentProjection(
      session: _session,
      revision: ++_revision,
      name: source.name,
      filePath: source.filePath,
      chapters: chapters,
    );
  }
}
