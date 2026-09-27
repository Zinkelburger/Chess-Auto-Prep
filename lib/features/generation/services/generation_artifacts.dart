/// Tree codecs and complete bundle staging over the artifact authority.
library;

import 'dart:convert';
import 'dart:isolate';

import '../models/generation_artifacts.dart';
import '../models/generation_recovery.dart';
import '../repositories/generation_artifact_repository.dart';
import '../../../chess_core/generation/build_tree_node.dart';
import '../../../chess_core/generation/expectimax_probe_codec.dart';
import '../../../chess_core/generation/trap_line_info.dart';
import '../../../chess_core/generation/tree_serialization.dart';

/// Authoritative saved trees; unverified legacy outputs require a separate,
/// explicit preview and are never used to resume or extend a generated cache.
typedef SavedExpectimaxDatabase = ({BuildTree? tree, List<BuildTree> probes});

/// A detached, read-only inspection. Parsed values never enter the live
/// generated database, resume path or repository publication protocol.
class GenerationRecoveryInspection {
  GenerationRecoveryInspection(this.snapshot, this.items);
  final GenerationRecoverySnapshot snapshot;
  final List<GenerationRecoveryItem> items;
}

class GenerationRecoveryItem {
  const GenerationRecoveryItem({
    required this.file,
    this.tree,
    this.trap,
    this.error,
  });
  final GenerationRecoveryFile file;
  GenerationRecoveryFileKind get kind => file.kind;
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

  Future<GenerationRecoveryInspection> inspectRecovery(
    GenerationRecoveryEntry entry,
  ) async {
    final snapshot = await repository.readRecovery(entry);
    final items = await Isolate.run(() {
      final items = <GenerationRecoveryItem>[];
      for (final file in snapshot.files) {
        void failure(Object error) => items.add(
          GenerationRecoveryItem(
            file: file,
            error: error is GenerationArtifactFailure
                ? error
                : GenerationArtifactFailure(
                    '$error',
                    kind: GenerationArtifactFailureKind.decode,
                  ),
          ),
        );
        void decodeTree(String text) {
          try {
            items.add(
              GenerationRecoveryItem(file: file, tree: deserializeTree(text)),
            );
          } catch (error) {
            failure(error);
          }
        }

        if (file.error case final error?) failure(error);
        final text = file.text;
        if (text == null) continue;
        try {
          switch (file.kind) {
            case GenerationRecoveryFileKind.tree:
            case GenerationRecoveryFileKind.partial:
              decodeTree(text);
            case GenerationRecoveryFileKind.probes:
              final data = jsonDecode(text) as Map<String, dynamic>;
              for (final probe in data['trees'] as List) {
                if (probe is String) {
                  decodeTree(probe);
                } else {
                  failure(const FormatException('Invalid saved probe entry'));
                }
              }
            case GenerationRecoveryFileKind.traps:
              final data = jsonDecode(text) as Map<String, dynamic>;
              for (final trap in data['traps'] as List) {
                try {
                  items.add(
                    GenerationRecoveryItem(
                      file: file,
                      trap: TrapLineInfo.fromJson(trap as Map<String, dynamic>),
                    ),
                  );
                } catch (error) {
                  failure(error);
                }
              }
            case GenerationRecoveryFileKind.course:
            case GenerationRecoveryFileKind.modelGames:
            case GenerationRecoveryFileKind.manifest:
            case GenerationRecoveryFileKind.receipt:
              items.add(GenerationRecoveryItem(file: file));
          }
          if (!items.any((item) => identical(item.file, file))) {
            items.add(GenerationRecoveryItem(file: file));
          }
        } catch (error) {
          failure(error);
        }
      }
      return items;
    });
    return GenerationRecoveryInspection(snapshot, [
      for (final item in items)
        GenerationRecoveryItem(
          file: snapshot.files.singleWhere((file) => file.kind == item.kind),
          tree: item.tree,
          trap: item.trap,
          error: item.error,
        ),
    ]);
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
