import 'package:dartchess/dartchess.dart' show Side;

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
