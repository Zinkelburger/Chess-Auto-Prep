import 'document_ref.dart';
import 'training_rows.dart';

/// The fixed shared training files whose bytes supplied one progress read.
const trainingParticipants = [
  reviewsFile,
  streaksFile,
  historyFile,
  attemptsFile,
];

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
