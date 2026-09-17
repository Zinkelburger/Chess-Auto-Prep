/// Tree codecs and complete bundle staging over the artifact authority.
library;

import 'dart:convert';
import 'dart:isolate';

import '../models/generation_artifacts.dart';
import '../repositories/generation_artifact_repository.dart';
import '../../../models/build_tree_node.dart';
import '../../../models/trap_line_info.dart';
import '../../../services/generation/expectimax_probe.dart';
import '../../../services/generation/tree_serialization.dart';

/// Authoritative saved trees; unverified legacy outputs require a separate,
/// explicit preview and are never used to resume or extend a generated cache.
typedef SavedExpectimaxDatabase = ({BuildTree? tree, List<BuildTree> probes});

class GenerationArtifacts {
  GenerationArtifacts(this.repository);
  final GenerationArtifactRepository repository;

  Future<GenerationArtifactProposal> prepareBundle(
    GenerationArtifactRun run, {
    required BuildTree tree,
    required List<BuildTree> probes,
    required List<TrapLineInfo> traps,
  }) async {
    final treeJson = await serializeTreeInIsolate(tree);
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
    final json = await serializeTreeInIsolate(tree, indent: false);
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
        : await serializeTreeInIsolate(mainTree);
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
