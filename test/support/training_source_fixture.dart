import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_document_store.dart';
import 'package:chess_auto_prep/features/training/models/training_source_context.dart';

import 'scripted_document_store.dart' show snapshot;

/// Explicit observations for pure controller tests whose repositories are fakes.
Map<String, TrainingSourceContext> scriptedTrainingSources(
  Iterable<String> paths,
) => {
  for (final path in paths)
    path: TrainingSourceContext(
      path: path,
      snapshot: snapshot('1. e4 *', path: path),
    ),
};

/// Native fixtures must observe their real source before accepting a write.
Future<TrainingSourceContext> captureTrainingSource(
  PgnDocumentStore documents,
  String path,
) async {
  final opened = await documents.open(path);
  if (opened is! PgnOpened)
    throw StateError('Fixture source did not open: $path ($opened)');
  return TrainingSourceContext(path: path, snapshot: opened.snapshot);
}
