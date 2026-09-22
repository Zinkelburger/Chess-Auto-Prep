import '../../documents/models/pgn_document.dart';
import 'generation_publication.dart';

enum GenerationArtifactKind { tree, probes, traps, partial }

enum GenerationArtifactOrigin { current, absent, stale }

/// An authoritative generation; recovery observations use a separate type.
class GenerationArtifactSnapshot {
  GenerationArtifactSnapshot({
    required this.origin,
    Map<GenerationArtifactKind, String> payloads = const {},
    this.generationId,
    this.notice,
  }) : payloads = Map.unmodifiable(payloads);
  final GenerationArtifactOrigin origin;
  final Map<GenerationArtifactKind, String> payloads;

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
  enumerate,
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
