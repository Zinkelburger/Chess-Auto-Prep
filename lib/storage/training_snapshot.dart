import 'document_ref.dart';

/// Native proofs from the same observations the progress reader decoded.
/// Absence is an input too; a later creation invalidates this snapshot.
final class TrainingReadSet {
  TrainingReadSet({
    required this.documentsPath,
    required this.canonicalDocuments,
    required Map<String, Revision?> files,
  }) : files = Map.unmodifiable(files);

  final String documentsPath;
  final String canonicalDocuments;
  final Map<String, Revision?> files;
}
