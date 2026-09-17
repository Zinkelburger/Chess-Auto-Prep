import '../../documents/models/pgn_document.dart';

/// Source observation captured before an expensive generation starts.
class GenerationSource {
  GenerationSource({
    required this.runId,
    required this.path,
    required this.snapshot,
    required Map<String, dynamic> config,
  }) : config = snapshotConfig(config);

  final String runId;
  final String path;
  final PgnSnapshot? snapshot;
  final Map<String, dynamic> config;

  static Map<String, dynamic> snapshotConfig(Map<String, dynamic> value) =>
      Map.unmodifiable({
        for (final entry in value.entries) entry.key: _freeze(entry.value),
      });

  static dynamic _freeze(dynamic value) => switch (value) {
    Map<String, dynamic>() => snapshotConfig(value),
    List() => List.unmodifiable(value.map(_freeze)),
    _ => value,
  };
}

/// Complete proposed output retained before the authoritative PGN is changed.
class GenerationDraft {
  const GenerationDraft({
    required this.source,
    required this.content,
    required this.modelGames,
  });

  final GenerationSource source;
  final String content;
  final String? modelGames;
}

class StagedGeneration {
  const StagedGeneration({required this.manifestPath, this.modelGamesPath});
  final String manifestPath;
  final String? modelGamesPath;
}

class GenerationStagingFailed implements Exception {
  const GenerationStagingFailed(this.manifestPath, this.error);
  final String manifestPath;
  final Object error;

  @override
  String toString() =>
      'Generation staging failed at $manifestPath: $error. '
      'The source PGN was not changed.';
}

sealed class GenerationPublicationResult {
  const GenerationPublicationResult(this.staged);
  final StagedGeneration staged;
}

final class GenerationPublished extends GenerationPublicationResult {
  const GenerationPublished(super.staged, this.snapshot, {this.receiptError});
  final PgnSnapshot snapshot;

  /// The PGN committed, but its receipt needs reconciliation. Never append again.
  final Object? receiptError;
}

final class GenerationPublicationRefused extends GenerationPublicationResult {
  const GenerationPublicationRefused(super.staged, this.reason);
  final Object reason;
}

/// An in-flight source replacement may have committed. Retain its draft and
/// reconcile the observed revision; automatically retrying could double lines.
final class GenerationPublicationUncertain extends GenerationPublicationResult {
  const GenerationPublicationUncertain(super.staged, this.write);
  final PgnWriteUncertain write;
}
