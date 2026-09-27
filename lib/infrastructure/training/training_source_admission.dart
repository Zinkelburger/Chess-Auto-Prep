import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../utils/file_text_reader.dart';
import 'package:document_file_io/document_file_io.dart';

import '../../features/training/models/training_source_context.dart';

/// Called inside storage's recovery domain and the training file mutex.
/// Never enter a public document store here: its guard is non-reentrant.
Future<void> validateTrainingSource(
  TrainingSourceContext source,
  String path,
) async {
  if (source.path != path) {
    throw StateError('Training source context does not match $path.');
  }
  final snapshot = source.snapshot;
  final current = await observeFile(snapshot.path);
  if (current.status != 0 && current.status != 1) {
    throw FileSystemException(
      'Cannot verify the training source',
      snapshot.path,
    );
  }
  if (current.status == 1 ||
      current.identity != snapshot.revision.nativeIdentity ||
      current.sha256Hex != snapshot.revision.sha256) {
    throw TrainingSourceChanged();
  }
  final originalPath = await File(source.path).resolveSymbolicLinks();
  if (!p.equals(originalPath, snapshot.path)) throw TrainingSourceChanged();
}

/// Explicit compatibility policy for platforms still using the content-only
/// document adapter. It cannot detect replacement with identical bytes.
Future<void> validateLegacyTrainingSource(
  TrainingSourceContext source,
  String path,
) async {
  final snapshot = source.snapshot;
  if (source.path != path ||
      snapshot.revision.nativeIdentity != 'legacy-content') {
    throw StateError(
      'Training source does not belong to the legacy document adapter.',
    );
  }
  final content = await readTextFile(File(snapshot.path));
  if (sha256.convert(utf8.encode(content)).toString() !=
      snapshot.revision.sha256) {
    throw TrainingSourceChanged();
  }
}
