import 'dart:typed_data';

import 'generation_artifacts.dart';
import 'generation_publication.dart';

enum GenerationRecoveryFileKind {
  tree,
  probes,
  traps,
  partial,
  course,
  modelGames,
  manifest,
  receipt;

  GenerationArtifactKind? get artifactKind => switch (this) {
    tree => GenerationArtifactKind.tree,
    probes => GenerationArtifactKind.probes,
    traps => GenerationArtifactKind.traps,
    partial => GenerationArtifactKind.partial,
    _ => null,
  };

  String get extension => this == course || this == modelGames ? 'pgn' : 'json';
}

enum GenerationRecoverySource { unrecorded, matches, changed, unavailable }

enum GenerationRecoveryIntegrity { unrecorded, matches, changed }

enum GenerationRecoveryReceipt { absent, recorded, unreadable }

/// Verified sibling observations survive an inaccessible subtree. A root
/// identity failure is fatal and never produces a partial discovery result.
class GenerationRecoverySources {
  GenerationRecoverySources(
    Iterable<GenerationRecoverySourceEntry> entries, {
    Map<String, GenerationArtifactFailure> failures = const {},
  }) : entries = List.unmodifiable(entries),
       failures = Map.unmodifiable(failures);
  final List<GenerationRecoverySourceEntry> entries;
  final Map<String, GenerationArtifactFailure> failures;
}

/// A chapter namespace discovered under the configured repertoire root.
/// The path comes from that namespace, never the manifest's source field.
class GenerationRecoverySourceEntry {
  const GenerationRecoverySourceEntry({
    required this.path,
    required this.label,
  });
  final String path;
  final String label;
}

/// A catalog observation, not a publication/resume capability. Identity is
/// rechecked when loading; the caller cannot redirect the chapter or run.
class GenerationRecoveryEntry {
  const GenerationRecoveryEntry({
    required this.chapterPath,
    required this.id,
    required this.path,
    this.legacy = false,
    this.directoryIdentity,
    this.error,
  });
  final String chapterPath;
  final String id;
  final String path;
  final bool legacy;
  final String? directoryIdentity;
  final GenerationArtifactFailure? error;
}

class GenerationRecoveryCatalog {
  GenerationRecoveryCatalog(
    Iterable<GenerationRecoveryEntry> entries, {
    this.error,
  }) : entries = List.unmodifiable(entries);
  final List<GenerationRecoveryEntry> entries;

  /// A retained namespace failure does not hide readable legacy siblings.
  final GenerationArtifactFailure? error;
}

/// One safe native observation. Export uses these immutable bytes even if the
/// source changes later; decoding/integrity failure never discards them.
class GenerationRecoveryFile {
  GenerationRecoveryFile({
    required this.kind,
    required this.path,
    List<int>? bytes,
    this.text,
    this.error,
    this.integrity = GenerationRecoveryIntegrity.unrecorded,
  }) : bytes = bytes == null
           ? null
           : Uint8List.fromList(bytes).asUnmodifiableView();
  final GenerationRecoveryFileKind kind;
  final String path;
  final List<int>? bytes;
  final String? text;
  final GenerationArtifactFailure? error;
  final GenerationRecoveryIntegrity integrity;
}

class GenerationRecoverySnapshot {
  GenerationRecoverySnapshot({
    required this.entry,
    required Iterable<GenerationRecoveryFile> files,
    this.runId,
    this.recordedSource,
    this.sourceState = GenerationRecoverySource.unrecorded,
    this.receipt = GenerationRecoveryReceipt.absent,
    this.namedBySelection = false,
    Map<String, dynamic> config = const {},
    this.error,
  }) : files = List.unmodifiable(files),
       config = GenerationSource.snapshotConfig(config);
  final GenerationRecoveryEntry entry;
  final List<GenerationRecoveryFile> files;
  final String? runId;
  final String? recordedSource;
  final Map<String, dynamic> config;
  final GenerationRecoverySource sourceState;

  /// Evidence only: a missing receipt is not proof that publication failed.
  final GenerationRecoveryReceipt receipt;

  /// The pointer named this directory when observed. This is not certification
  /// of current analysis and does not distinguish old selection from no selection.
  final bool namedBySelection;
  final GenerationArtifactFailure? error;
}
