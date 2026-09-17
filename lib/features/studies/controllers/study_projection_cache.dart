import 'package:flutter/foundation.dart' show mapEquals;

import '../../../chess_core/moves/move_tree_snapshot.dart';
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

  final _changedNodes = <StudyChapter, Set<int>>{};
  final _bulkChanges = <StudyChapter>{};

  void changed(StudyChapter chapter, {TreePath? path}) {
    if (path == null) {
      _bulkChanges.add(chapter);
    } else {
      _changedNodes
          .putIfAbsent(chapter, () => {})
          .addAll(chapter.tree.nodeListAt(path).map((node) => node.id));
    }
  }

  StudyDocumentProjection read(StudyDocument source, int editRevision) {
    if (!identical(source, _source)) {
      _source = source;
      _session = Object();
      _document = null;
      _chapters.clear();
      _changedNodes.clear();
      _bulkChanges.clear();
    }
    final previous = _document;
    if (previous != null &&
        _editRevision == editRevision &&
        previous.name == source.name &&
        previous.filePath == source.filePath) {
      return previous;
    }
    _editRevision = editRevision;
    _revision++;
    final current = source.chapters.toSet();
    _chapters.removeWhere((chapter, _) => !current.contains(chapter));
    final chapters = <StudyChapterProjection>[];
    for (final chapter in source.chapters) {
      final cached = _chapters[chapter];
      final old = cached?.$2;
      final sameTree =
          cached != null &&
          identical(cached.$1, chapter.tree) &&
          old!.tree.version == chapter.tree.version;
      if (sameTree &&
          old.name == chapter.name &&
          old.orientation == chapter.orientation &&
          mapEquals(old.headers, chapter.headers)) {
        chapters.add(old);
        continue;
      }
      final next = StudyChapterProjection(
        session: _session,
        key: old?.key ?? Object(),
        revision: _revision,
        name: chapter.name,
        orientation: chapter.orientation,
        headers: chapter.headers,
        tree: sameTree
            ? old.tree
            : cached != null &&
                  identical(cached.$1, chapter.tree) &&
                  !_bulkChanges.contains(chapter) &&
                  _changedNodes.containsKey(chapter)
            ? MoveTreeSnapshot.revise(
                chapter.tree,
                previous: old!.tree,
                changedNodeIds: _changedNodes[chapter]!,
              )
            : MoveTreeSnapshot.capture(
                chapter.tree,
                identity: cached != null && identical(cached.$1, chapter.tree)
                    ? old!.tree.identity
                    : null,
              ),
      );
      _chapters[chapter] = (chapter.tree, next);
      chapters.add(next);
    }
    _changedNodes.clear();
    _bulkChanges.clear();
    return _document = StudyDocumentProjection(
      session: _session,
      revision: _revision,
      name: source.name,
      filePath: source.filePath,
      chapters: chapters,
    );
  }
}
