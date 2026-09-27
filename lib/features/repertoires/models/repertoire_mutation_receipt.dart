import '../../../chess_core/pgn/repertoire_document_mutation.dart';
import '../../documents/models/pgn_document.dart';

/// Native provenance and logical steps from one accepted chapter mutation.
/// Intermediate logical states are never represented as persisted revisions.
class RepertoireMutationReceipt {
  RepertoireMutationReceipt({
    required this.requestedDocumentPath,
    required this.before,
    required this.after,
    required this.mutation,
  });
  final String requestedDocumentPath;
  final PgnSnapshot before;
  final PgnSnapshot after;
  final RepertoireAppendPlan mutation;

  void validate({required String path, required List<String> requestedPath}) {
    mutation.validate(requestedPath: requestedPath);
    if (requestedDocumentPath != path ||
        before.path != after.path ||
        before.revision.documentId != after.revision.documentId ||
        before.content != mutation.previousContent ||
        after.content != mutation.updatedContent ||
        (mutation.steps.isEmpty && before.revision != after.revision) ||
        (mutation.steps.isNotEmpty && before.revision == after.revision)) {
      throw StateError('Invalid native repertoire mutation receipt');
    }
  }
}
