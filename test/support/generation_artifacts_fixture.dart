import 'package:chess_auto_prep/features/generation/services/generation_artifacts.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/generation/models/generation_artifacts.dart';
import 'package:chess_auto_prep/features/generation/models/generation_recovery.dart';
import 'package:chess_auto_prep/features/generation/models/generation_publication.dart';
import 'package:chess_auto_prep/features/generation/repositories/generation_artifact_repository.dart';

/// Controller tests use an isolated authority with no platform/filesystem work.
/// Native revision and interruption behavior is exercised by repository tests.
class MemoryGenerationArtifacts implements GenerationArtifactRepository {
  final saved = <String, Map<GenerationArtifactKind, String>>{};
  final proposals =
      <GenerationArtifactProposal, Map<GenerationArtifactKind, String>>{};
  final active = <GenerationArtifactRun>{};
  int sequence = 0;
  final generations = <String, String>{};
  Object? failure;
  Future<void> Function(String)? beforeRead;

  @override
  Future<GenerationArtifactSnapshot> read(String path) async {
    await beforeRead?.call(path);
    return GenerationArtifactSnapshot(
      origin: saved.containsKey(path)
          ? GenerationArtifactOrigin.current
          : GenerationArtifactOrigin.absent,
      payloads: saved[path] ?? {},
      generationId: generations[path] ?? 'fixture',
    );
  }

  @override
  Future<GenerationRecoverySources> listRecoverySources() async =>
      GenerationRecoverySources(const []);

  @override
  Future<GenerationRecoveryCatalog> listRecovery(String path) async =>
      GenerationRecoveryCatalog([
        GenerationRecoveryEntry(
          chapterPath: path,
          id: 'legacy',
          path: path,
          legacy: true,
        ),
      ]);
  @override
  Future<GenerationRecoverySnapshot> readRecovery(
    GenerationRecoveryEntry entry,
  ) async => GenerationRecoverySnapshot(entry: entry, files: const []);
  @override
  Future<void> exportRecovery(
    GenerationRecoveryFile file,
    String destination,
  ) async =>
      throw UnimplementedError('Recovery export requires an explicit fixture');

  @override
  Future<GenerationArtifactRun> begin(
    String path,
    Map<String, dynamic> config, {
    GenerationSource? source,
    String? expectedGenerationId,
  }) async {
    if (expectedGenerationId != null &&
        (generations[path] ?? 'fixture') != expectedGenerationId) {
      throw StateError('Saved generation changed');
    }
    final run = GenerationArtifactRun(
      runId: '${++sequence}',
      path: path,
      source: source?.snapshot,
      config: config,
    );
    active.add(run);
    return run;
  }

  @override
  Future<GenerationArtifactProposal> prepare(
    GenerationArtifactRun run,
    Map<GenerationArtifactKind, String?> changes,
  ) async {
    if (failure case final error?) throw error;
    if (!active.contains(run)) throw StateError('Closed artifact run');
    final next = {...?saved[run.path]};
    for (final entry in changes.entries) {
      if (entry.value == null) {
        next.remove(entry.key);
      } else {
        next[entry.key] = entry.value!;
      }
    }
    final proposal = GenerationArtifactProposal(
      'memory-${++sequence}/manifest.json',
    );
    proposals[proposal] = next;
    return proposal;
  }

  @override
  Future<void> select(
    GenerationArtifactRun run,
    GenerationArtifactProposal proposal, {
    PgnSnapshot? publishedSource,
  }) async {
    if (failure case final error?) throw error;
    if (!active.contains(run)) throw StateError('Closed artifact run');
    saved[run.path] = proposals.remove(proposal)!;
    generations[run.path] = proposal.manifestPath;
  }

  @override
  void close(GenerationArtifactRun run) => active.remove(run);
}

GenerationArtifacts generationArtifactsFixture() =>
    GenerationArtifacts(MemoryGenerationArtifacts());
