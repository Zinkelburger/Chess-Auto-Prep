import 'dart:typed_data';

import '../../documents/models/pgn_document.dart';
import 'generation_publication.dart';

enum GenerationArtifactKind { tree, probes, traps, partial }

enum GenerationArtifactOrigin { current, legacy, absent, stale }

/// A verified generation, or an explicitly requested unverified legacy preview.
class GenerationArtifactSnapshot {
  GenerationArtifactSnapshot({
    required this.origin,
    Map<GenerationArtifactKind, String> payloads = const {},
    Map<GenerationArtifactKind, List<int>> originalBytes = const {},
    Map<GenerationArtifactKind, GenerationArtifactFailure> readFailures =
        const {},
    this.generationId,
    this.notice,
  }) : payloads = Map.unmodifiable(payloads),
       originalBytes = Map.unmodifiable({
         for (final entry in originalBytes.entries)
           entry.key: Uint8List.fromList(entry.value).asUnmodifiableView(),
       }),
       readFailures = Map.unmodifiable(readFailures);
  final GenerationArtifactOrigin origin;
  final Map<GenerationArtifactKind, String> payloads;

  /// Exact legacy file bytes for explicit recovery export, never publication.
  final Map<GenerationArtifactKind, List<int>> originalBytes;
  final Map<GenerationArtifactKind, GenerationArtifactFailure> readFailures;
  final String? generationId;
  final String? notice;
}

/// Capability captured before work starts; only its creating repository may
/// advance it. A later run cannot inherit an earlier run's pending writes.
class GenerationArtifactRun {
  GenerationArtifactRun({
    required this.runId,
    required this.path,
    required this.source,
    required Map<String, dynamic> config,
  }) : config = GenerationSource.snapshotConfig(config);
  final String runId;
  final String path;
  final PgnSnapshot? source;
  final Map<String, dynamic> config;
}

class GenerationArtifactProposal {
  const GenerationArtifactProposal(this.manifestPath);
  final String manifestPath;
}

enum GenerationArtifactFailureKind {
  publication,
  read,
  decode,
  export,
  collision,
  uncertain,
}

class GenerationArtifactFailure implements Exception {
  const GenerationArtifactFailure(
    this.reason, {
    this.proposalPath,
    this.kind = GenerationArtifactFailureKind.publication,
  });
  final GenerationArtifactFailureKind kind;
  final String reason;
  final String? proposalPath;
  @override
  String toString() => proposalPath == null
      ? reason
      : '$reason. Artifact proposal retained at $proposalPath';
}
