import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/generation/models/generation_artifacts.dart';
import 'package:chess_auto_prep/features/generation/models/generation_recovery.dart';
import 'package:chess_auto_prep/features/generation/services/generation_artifacts.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/generation/storage_generation_artifact_repository.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/utils/atomic_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/legacy_analysis_fixture.dart';

void main() {
  late Directory root;
  late String chapter;
  late StorageGenerationArtifactRepository repository;
  StorageGenerationArtifactRepository reopen({
    AtomicFileWriter? writer,
    Future<void> Function(String)? flush,
  }) => StorageGenerationArtifactRepository(
    storage: IOStorageService(documentsRoot: root, supportRoot: root),
    documents: NativePgnDocumentStore(),
    recoveryWriter: writer,
    flushRecoveryDirectory: flush,
  );
  const suffixes = {
    GenerationArtifactKind.tree: 'tree',
    GenerationArtifactKind.probes: 'expectimax',
    GenerationArtifactKind.partial: 'partial_tree',
    GenerationArtifactKind.traps: 'traps',
  };
  File original(GenerationArtifactKind kind) =>
      File(p.join(root.path, 'Main_${suffixes[kind]}.json'));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('recovery-recovery-');
    chapter = p.join(root.path, 'Main.pgn');
    await File(
      chapter,
    ).writeAsString('[Event "Different current chapter"]\n\n1. d4 *');
    for (final entry in legacyRecoveryPayloads().entries) {
      await original(entry.key).writeAsString(entry.value);
    }
    repository = reopen();
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'real legacy reads recover all kinds across restart without selecting them',
    () async {
      final baseline = await File(chapter).readAsBytes();
      final inspected = await GenerationArtifacts(
        repository,
      ).inspectRecovery((await repository.listRecovery(chapter)).entries.first);
      expect(inspected.items, hasLength(4));
      expect(inspected.items.where((i) => i.tree != null), hasLength(3));
      expect(
        inspected.items
            .singleWhere((i) => i.kind == GenerationRecoveryFileKind.partial)
            .tree!
            .buildComplete,
        false,
      );
      expect(
        inspected.items.singleWhere((i) => i.trap != null).trap!.popularMove,
        'f6',
      );
      expect(
        await GenerationArtifacts(repository).readPartial(chapter),
        isNull,
      );
      expect(
        (await repository.read(chapter)).origin,
        GenerationArtifactOrigin.absent,
      );
      final restarted = await GenerationArtifacts(
        reopen(),
      ).inspectRecovery((await repository.listRecovery(chapter)).entries.first);
      expect(
        restarted.snapshot.files.map((f) => f.bytes).toList(),
        inspected.snapshot.files.map((f) => f.bytes).toList(),
      );
      expect(await File(chapter).readAsBytes(), baseline);
      expect(
        await File(
          StorageGenerationArtifactRepository.pointerPath(chapter),
        ).exists(),
        false,
      );
    },
  );

  test(
    'an edited legacy model-game companion stays readable and exports exact bytes',
    () async {
      final file = File(p.join(root.path, 'Main_model_games.pgn'));
      final bytes = [
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('[Event "User edited companion"]\n\n1. c4 *'),
      ];
      await file.writeAsBytes(bytes);
      final entry = (await repository.listRecovery(chapter)).entries.first;
      final inspected = await GenerationArtifacts(
        repository,
      ).inspectRecovery(entry);
      final companion = inspected.snapshot.files.singleWhere(
        (f) => f.kind == GenerationRecoveryFileKind.modelGames,
      );
      expect(companion.text, contains('User edited companion'));
      final destination = p.join(root.path, 'Recovered companion.pgn');
      await repository.exportRecovery(companion, destination);
      expect(await File(destination).readAsBytes(), bytes);
      expect(await file.readAsBytes(), bytes);
    },
  );

  test(
    'malformed entry and unsafe file do not hide healthy probes or partial',
    () async {
      await original(GenerationArtifactKind.tree).writeAsString('{broken');
      await original(GenerationArtifactKind.traps).delete();
      await Link(
        original(GenerationArtifactKind.traps).path,
      ).create(original(GenerationArtifactKind.partial).path);
      final result = await GenerationArtifacts(
        repository,
      ).inspectRecovery((await repository.listRecovery(chapter)).entries.first);
      expect(result.items.where((i) => i.error != null), hasLength(2));
      expect(result.items.where((i) => i.tree != null), hasLength(2));
      expect(
        result.snapshot.files.any(
          (f) => f.kind == GenerationRecoveryFileKind.tree && f.bytes != null,
        ),
        true,
      );
      expect(
        result.snapshot.files.any(
          (f) => f.kind == GenerationRecoveryFileKind.traps && f.bytes != null,
        ),
        false,
      );
    },
  );

  test('a corrupt probe entry does not hide other saved probes', () async {
    final data =
        jsonDecode(legacyRecoveryPayloads()[GenerationArtifactKind.probes]!)
            as Map<String, dynamic>;
    (data['trees'] as List).insert(0, '{broken');
    await original(
      GenerationArtifactKind.probes,
    ).writeAsString(jsonEncode(data));
    final result = await GenerationArtifacts(
      repository,
    ).inspectRecovery((await repository.listRecovery(chapter)).entries.first);
    final probes = result.items
        .where((item) => item.kind == GenerationRecoveryFileKind.probes)
        .toList();
    expect(probes, hasLength(2));
    expect(probes.first.error?.kind, GenerationArtifactFailureKind.decode);
    expect(probes.last.tree?.totalNodes, 2);
  });

  test(
    'export preserves exact BOM, gzip and malformed bytes after original changes',
    () async {
      for (final bytes in [
        [
          0xef,
          0xbb,
          0xbf,
          ...utf8.encode(
            legacyRecoveryPayloads()[GenerationArtifactKind.tree]!,
          ),
        ],
        gzip.encode(
          utf8.encode(legacyRecoveryPayloads()[GenerationArtifactKind.tree]!),
        ),
        [0xff, 0x00, 0x80, 0x7b],
      ]) {
        final file = original(GenerationArtifactKind.tree);
        await file.writeAsBytes(bytes);
        final captured = await repository.readRecovery(
          (await repository.listRecovery(chapter)).entries.first,
        );
        await file.writeAsString('externally changed');
        final destination = p.join(root.path, 'Recovered-${bytes.length}.json');
        await repository.exportRecovery(
          captured.files.singleWhere(
            (f) => f.kind == GenerationRecoveryFileKind.tree,
          ),
          destination,
        );
        expect(await File(destination).readAsBytes(), bytes);
        expect(await file.readAsString(), 'externally changed');
      }
    },
  );

  test(
    'export collision and interrupted staging preserve destination and originals',
    () async {
      final captured = await repository.readRecovery(
        (await repository.listRecovery(chapter)).entries.first,
      );
      final destination = original(GenerationArtifactKind.tree);
      await expectLater(
        repository.exportRecovery(
          captured.files.singleWhere(
            (f) => f.kind == GenerationRecoveryFileKind.partial,
          ),
          destination.path,
        ),
        throwsA(isA<GenerationArtifactFailure>()),
      );
      expect(
        await destination.readAsBytes(),
        captured.files
            .singleWhere((f) => f.kind == GenerationRecoveryFileKind.tree)
            .bytes,
      );
      final interrupted = reopen(
        writer: AtomicFileWriter(
          testHook: (step) async {
            if (step == AtomicWriteStep.tempFlushed) {
              throw StateError('disk failed');
            }
          },
        ),
      );
      final path = p.join(root.path, 'Interrupted.json');
      await expectLater(
        interrupted.exportRecovery(
          captured.files.singleWhere(
            (f) => f.kind == GenerationRecoveryFileKind.tree,
          ),
          path,
        ),
        throwsA(isA<GenerationArtifactFailure>()),
      );
      expect(await File(path).exists(), false);
      expect(
        await destination.readAsBytes(),
        captured.files
            .singleWhere((f) => f.kind == GenerationRecoveryFileKind.tree)
            .bytes,
      );
    },
  );

  test(
    'uncertain flush reports inspection path, never replays or changes selection',
    () async {
      final run = await repository.begin(chapter, {});
      await repository.select(
        run,
        await repository.prepare(run, {GenerationArtifactKind.tree: 'current'}),
      );
      repository.close(run);
      final before = await repository.read(chapter);
      final failing = reopen(
        flush: (_) async => throw StateError('acknowledgement failed'),
      );
      final snapshot = await failing.readRecovery(
        (await failing.listRecovery(chapter)).entries.first,
      );
      final path = p.join(root.path, 'Uncertain.json');
      await expectLater(
        failing.exportRecovery(
          snapshot.files.singleWhere(
            (f) => f.kind == GenerationRecoveryFileKind.partial,
          ),
          path,
        ),
        throwsA(
          isA<GenerationArtifactFailure>()
              .having((e) => e.proposalPath, 'recovery path', path)
              .having(
                (e) => e.reason,
                'uncertain message',
                contains('may already exist'),
              ),
        ),
      );
      expect(
        await File(path).readAsBytes(),
        snapshot.files
            .singleWhere((f) => f.kind == GenerationRecoveryFileKind.partial)
            .bytes,
      );
      expect((await reopen().read(chapter)).generationId, before.generationId);
      await expectLater(
        repository.exportRecovery(
          snapshot.files.singleWhere(
            (f) => f.kind == GenerationRecoveryFileKind.tree,
          ),
          path,
        ),
        throwsA(isA<GenerationArtifactFailure>()),
      );
      expect(
        await File(path).readAsBytes(),
        snapshot.files
            .singleWhere((f) => f.kind == GenerationRecoveryFileKind.partial)
            .bytes,
      );
    },
  );
}
