import '../../documents/models/document_save_state.dart';
import '../../documents/models/pgn_document.dart';

/// Recovery data, not authority to overwrite a file observed after restart.
class StudyWorkspaceSnapshot {
  StudyWorkspaceSnapshot({
    required this.name,
    required this.path,
    required this.content,
    required this.dirty,
    this.baseline,
    this.uncertain = false,
    this.uncertainPath,
    List<RetainedDocumentDraft> retainedDrafts = const [],
    this.chapter = 0,
    List<int> cursor = const [],
    this.flipped = false,
  }) : retainedDrafts = List.unmodifiable(retainedDrafts),
       cursor = List.unmodifiable(cursor);
  final String name;
  final String path;
  final String content;
  final bool dirty;
  final PgnSnapshot? baseline;
  final bool uncertain;
  final String? uncertainPath;
  final List<RetainedDocumentDraft> retainedDrafts;
  final int chapter;
  final List<int> cursor;
  final bool flipped;
  bool get needsRecovery => dirty || uncertain || retainedDrafts.isNotEmpty;
}
