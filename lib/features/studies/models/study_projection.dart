import 'package:dartchess/dartchess.dart' show Side, Position;
import '../../../chess_core/moves/tree_path.dart';

import '../../../chess_core/moves/move_tree_snapshot.dart';
import 'study_document.dart';

/// An immutable document projection, independent of the navigation cursor and
/// disk baseline. The session token prevents equality across document opens.
final class StudyDocumentProjection extends StudyDocumentData {
  StudyDocumentProjection({
    required this.session,
    required this.revision,
    required this.name,
    required this.filePath,
    required List<StudyChapterProjection> chapters,
  }) : chapters = List.unmodifiable(chapters);

  final Object session;
  final int revision;
  @override
  final String name;
  @override
  final String? filePath;
  @override
  final List<StudyChapterProjection> chapters;

  @override
  bool operator ==(Object other) =>
      other is StudyDocumentProjection &&
      session == other.session &&
      revision == other.revision;
  @override
  int get hashCode => Object.hash(session, revision, StudyDocumentProjection);
}

final class StudyChapterProjection extends StudyChapterData {
  StudyChapterProjection({
    required this.session,
    required this.key,
    required this.revision,
    required this.name,
    required this.orientation,
    required Map<String, String> headers,
    required this.tree,
  }) : headers = Map.unmodifiable(headers);

  final Object session;
  final Object key;
  final int revision;
  @override
  final String name;
  @override
  final Side orientation;
  @override
  final Map<String, String> headers;
  @override
  final MoveTreeSnapshot tree;

  @override
  bool operator ==(Object other) =>
      other is StudyChapterProjection &&
      session == other.session &&
      key == other.key &&
      revision == other.revision;
  @override
  int get hashCode =>
      Object.hash(session, key, revision, StudyChapterProjection);
}

/// Small immutable chapter metadata, independent of move content.
final class StudyChapterSummary {
  const StudyChapterSummary({
    required this.key,
    required this.name,
    this.result,
  });
  final Object key;
  final String name;
  final String? result;
  @override
  bool operator ==(Object other) =>
      other is StudyChapterSummary &&
      key == other.key &&
      name == other.name &&
      result == other.result;
  @override
  int get hashCode => Object.hash(key, name, result);
}

final class StudyChapterListProjection {
  StudyChapterListProjection({
    required this.session,
    required this.revision,
    required List<StudyChapterSummary> chapters,
  }) : chapters = List.unmodifiable(chapters);
  final Object session;
  final int revision;
  final List<StudyChapterSummary> chapters;
  @override
  bool operator ==(Object other) =>
      other is StudyChapterListProjection &&
      session == other.session &&
      revision == other.revision;
  @override
  int get hashCode =>
      Object.hash(session, revision, StudyChapterListProjection);
}

/// The cursor's values have a view revision, separate from both tree and disk
/// revisions. Edits elsewhere in the document leave this projection unchanged.
final class StudyCursorProjection {
  StudyCursorProjection({
    required this.session,
    required this.chapterKey,
    required this.revision,
    required TreePath path,
    required this.position,
    required this.flipped,
    required this.comment,
    required List<int> nags,
  }) : path = TreePath.from(path.indices),
       nags = List.unmodifiable(nags);
  final Object session;
  final Object chapterKey;
  final int revision;
  final TreePath path;
  final Position position;
  final bool flipped;
  final String? comment;
  final List<int> nags;
  @override
  bool operator ==(Object other) =>
      other is StudyCursorProjection &&
      session == other.session &&
      chapterKey == other.chapterKey &&
      revision == other.revision;
  @override
  int get hashCode =>
      Object.hash(session, chapterKey, revision, StudyCursorProjection);
}

typedef StudyTitle = ({
  Object session,
  String name,
  String? filePath,
  bool canRename,
});
