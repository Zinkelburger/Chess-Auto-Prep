/// Tree codecs and complete bundle staging over the artifact authority.
library;

import '../../../chess_core/generation/expectimax_probe_codec.dart';
import 'dart:convert';
import 'dart:isolate';

import '../models/generation_artifacts.dart';
import '../repositories/generation_artifact_repository.dart';
import '../../../chess_core/generation/build_tree_node.dart';
import '../../../chess_core/generation/trap_line_info.dart';
import '../../../chess_core/generation/tree_serialization.dart';

/// Authoritative saved trees; unverified legacy outputs require a separate,
/// explicit preview and are never used to resume or extend a generated cache.
typedef SavedExpectimaxDatabase = ({BuildTree? tree, List<BuildTree> probes});

/// A detached, read-only inspection. Parsed values never enter the live
/// generated database, resume path or repository publication protocol.
class LegacyAnalysisInspection {
  LegacyAnalysisInspection(this.snapshot, this.items);
  final GenerationArtifactSnapshot snapshot;
  final List<LegacyAnalysisItem> items;
}

class LegacyAnalysisItem {
  const LegacyAnalysisItem({
    required this.kind,
    this.tree,
    this.trap,
    this.error,
  });
  final GenerationArtifactKind kind;
  final BuildTree? tree;
  final TrapLineInfo? trap;
  final GenerationArtifactFailure? error;
}

class GenerationArtifacts {
  GenerationArtifacts(this.repository);
  final GenerationArtifactRepository repository;

  /// Capture the mutable tree before yielding, then encode only its detached
  /// document on a worker isolate. The codec itself is synchronous pure Dart.
  static Future<String> encodeTreeSnapshot(
    BuildTree tree, {
    bool indent = true,
  }) {
    final document = serializeTreeJson(tree);
    return Isolate.run(() => encodeTreeJson(document, indent: indent));
  }

  Future<LegacyAnalysisInspection> inspectLegacy(String path) async {
    final snapshot = await repository.readLegacy(path);
    final items = await Isolate.run(() {
      final items = <LegacyAnalysisItem>[
        for (final entry in snapshot.readFailures.entries)
          LegacyAnalysisItem(kind: entry.key, error: entry.value),
      ];
      for (final entry in snapshot.payloads.entries) {
        void decodeTree(String text) {
          try {
            items.add(
              LegacyAnalysisItem(kind: entry.key, tree: deserializeTree(text)),
            );
          } catch (error) {
            items.add(
              LegacyAnalysisItem(
                kind: entry.key,
                error: GenerationArtifactFailure(
                  '$error',
                  kind: GenerationArtifactFailureKind.decode,
                ),
              ),
            );
          }
        }

        try {
          switch (entry.key) {
            case GenerationArtifactKind.tree:
            case GenerationArtifactKind.partial:
              decodeTree(entry.value);
            case GenerationArtifactKind.probes:
              final data = jsonDecode(entry.value) as Map<String, dynamic>;
              for (final probe in data['trees'] as List) {
                if (probe is String) {
                  decodeTree(probe);
                } else {
                  items.add(
                    LegacyAnalysisItem(
                      kind: entry.key,
                      error: const GenerationArtifactFailure(
                        'Invalid saved probe entry',
                        kind: GenerationArtifactFailureKind.decode,
                      ),
                    ),
                  );
                }
              }
            case GenerationArtifactKind.traps:
              final data = jsonDecode(entry.value) as Map<String, dynamic>;
              for (final trap in data['traps'] as List) {
                try {
                  items.add(
                    LegacyAnalysisItem(
                      kind: entry.key,
                      trap: TrapLineInfo.fromJson(trap as Map<String, dynamic>),
                    ),
                  );
                } catch (error) {
                  items.add(
                    LegacyAnalysisItem(
                      kind: entry.key,
                      error: GenerationArtifactFailure(
                        '$error',
                        kind: GenerationArtifactFailureKind.decode,
                      ),
                    ),
                  );
                }
              }
          }
        } catch (error) {
          items.add(
            LegacyAnalysisItem(
              kind: entry.key,
              error: GenerationArtifactFailure(
                '$error',
                kind: GenerationArtifactFailureKind.decode,
              ),
            ),
          );
        }
      }
      return items;
    });
    return LegacyAnalysisInspection(snapshot, List.unmodifiable(items));
  }

  Future<GenerationArtifactProposal> prepareBundle(
    GenerationArtifactRun run, {
    required BuildTree tree,
    required List<BuildTree> probes,
    required List<TrapLineInfo> traps,
  }) async {
    final treeJson = await encodeTreeSnapshot(tree);
    final probesJson = await Isolate.run(
      () => ExpectimaxProbeCodec.encode(probes),
    );
    return repository.prepare(run, {
      GenerationArtifactKind.tree: treeJson,
      GenerationArtifactKind.probes: probesJson,
      GenerationArtifactKind.traps: jsonEncode({
        'traps': [for (final trap in traps) trap.toJson()],
      }),
      GenerationArtifactKind.partial: tree.buildComplete ? null : treeJson,
    });
  }

  Future<void> writePartialTree(
    BuildTree tree,
    GenerationArtifactRun run,
  ) async {
    final json = await encodeTreeSnapshot(tree, indent: false);
    final proposal = await repository.prepare(run, {
      GenerationArtifactKind.partial: json,
    });
    await repository.select(run, proposal);
  }

  Future<void> discardPartial(String path, String generationId) async {
    final run = await repository.begin(
      path,
      {},
      expectedGenerationId: generationId,
    );
    try {
      final proposal = await repository.prepare(run, {
        GenerationArtifactKind.partial: null,
      });
      await repository.select(run, proposal);
    } finally {
      repository.close(run);
    }
  }

  Future<({BuildTree tree, String generationId})?> readPartial(
    String path,
  ) async {
    final saved = await repository.read(path);
    final json = saved.payloads[GenerationArtifactKind.partial];
    final generationId = saved.generationId;
    if (json == null || generationId == null) return null;
    return (
      tree: await Isolate.run(() => deserializeTree(json)),
      generationId: generationId,
    );
  }

  Future<List<TrapLineInfo>?> readTraps(String path) async {
    final json = (await repository.read(
      path,
    )).payloads[GenerationArtifactKind.traps];
    if (json == null) return null;
    final data = jsonDecode(json) as Map<String, dynamic>;
    return [
      for (final value in data['traps'] as List)
        TrapLineInfo.fromJson(value as Map<String, dynamic>),
    ];
  }

  Future<SavedExpectimaxDatabase> readDatabase(String path) async {
    final saved = await repository.read(path);
    final treeJson = saved.payloads[GenerationArtifactKind.tree];
    final probesJson = saved.payloads[GenerationArtifactKind.probes];
    final tree = treeJson == null
        ? null
        : await Isolate.run(() => deserializeTree(treeJson));
    final probes = probesJson == null
        ? <BuildTree>[]
        : await Isolate.run(() => ExpectimaxProbeCodec.decode(probesJson));
    return (tree: tree, probes: probes);
  }

  Future<void> writeDatabase(
    GenerationArtifactRun run, {
    required List<BuildTree> probeTrees,
    required BuildTree? mainTree,
    required List<TrapLineInfo> traps,
  }) async {
    final probesJson = await Isolate.run(
      () => ExpectimaxProbeCodec.encode(probeTrees),
    );
    final treeJson = mainTree == null
        ? null
        : await encodeTreeSnapshot(mainTree);
    final proposal = await repository.prepare(run, {
      GenerationArtifactKind.probes: probesJson,
      GenerationArtifactKind.tree: treeJson,
      GenerationArtifactKind.traps: jsonEncode({
        'traps': [for (final trap in traps) trap.toJson()],
      }),
    });
    await repository.select(run, proposal);
  }
}
