import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/generation/controllers/generation_publication_controller.dart';
import 'package:chess_auto_prep/features/generation/models/generation_artifacts.dart';
import 'package:chess_auto_prep/features/generation/models/generation_publication.dart';
import 'package:chess_auto_prep/features/generation/models/generation_recovery.dart';
import 'package:chess_auto_prep/features/generation/services/generation_artifacts.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/generation/storage_generation_artifact_repository.dart';
import 'package:chess_auto_prep/infrastructure/generation/storage_generation_draft_repository.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/legacy_analysis_fixture.dart';

class _InterruptedStorage extends IOStorageService {
  _InterruptedStorage(Directory root, {this.suffix = 'tree.json'})
    : super(documentsRoot: root, supportRoot: root);
  final String suffix;
  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) {
    if (path.endsWith(suffix)) throw StateError('interrupted after manifest');
    return super.writeFile(
      path,
      content,
      createOnly: createOnly,
      expectedContent: expectedContent,
    );
  }
}

void main() {
  late Directory root;
  late String path;
  late IOStorageService storage;
  final documents = NativePgnDocumentStore();
  StorageGenerationArtifactRepository reopen() =>
      StorageGenerationArtifactRepository(
        storage: storage,
        documents: documents,
        recoveryRoot: () async => root.path,
      );
  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'retained-generation-recovery-',
    );
    path = p.join(root.path, 'Main.pgn');
    await File(path).writeAsString('[Event "Original"]\n\n1. e4 *');
    storage = IOStorageService(documentsRoot: root, supportRoot: root);
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'an inaccessible sibling preserves healthy orphan discovery and retries',
    () async {
      final healthy = Directory(
        p.join(root.path, 'Healthy', '.cap-generation', 'Deleted.pgn', 'run'),
      );
      final locked = Directory(p.join(root.path, 'Locked'));
      await healthy.create(recursive: true);
      await Directory(
        p.join(locked.path, '.cap-generation', 'Other.pgn', 'run'),
      ).create(recursive: true);
      await File(p.join(healthy.path, 'course.pgn')).writeAsString('1. e4 *');
      expect((await Process.run('chmod', ['000', locked.path])).exitCode, 0);
      try {
        final repository = reopen();
        final partial = await repository.listRecoverySources();
        expect(partial.entries.map((e) => e.label), ['Healthy/Deleted.pgn']);
        expect(partial.failures.keys, [locked.path]);
        expect(
          partial.failures.values.single.kind,
          GenerationArtifactFailureKind.enumerate,
        );
        final entries = await repository.listRecovery(
          partial.entries.single.path,
        );
        final snapshot = await repository.readRecovery(
          entries.entries.singleWhere((e) => !e.legacy),
        );
        expect(
          snapshot.files
              .singleWhere((f) => f.kind == GenerationRecoveryFileKind.course)
              .text,
          '1. e4 *',
        );
      } finally {
        expect((await Process.run('chmod', ['700', locked.path])).exitCode, 0);
      }
      final retried = await reopen().listRecoverySources();
      expect(retried.entries.map((e) => e.label), [
        'Healthy/Deleted.pgn',
        'Locked/Other.pgn',
      ]);
      expect(retried.failures, isEmpty);
      expect((await Process.run('chmod', ['000', root.path])).exitCode, 0);
      try {
        await expectLater(
          reopen().listRecoverySources(),
          throwsA(isA<GenerationArtifactFailure>()),
        );
      } finally {
        expect((await Process.run('chmod', ['700', root.path])).exitCode, 0);
      }
    },
    skip: !Platform.isLinux,
  );

  test(
    'orphan chapter namespaces remain discoverable without trusting manifest source paths',
    () async {
      final repository = reopen();
      final run = await repository.begin(path, {});
      final proposal = await repository.prepare(run, legacyRecoveryPayloads());
      repository.close(run);
      await File(path).delete();
      final sources = await repository.listRecoverySources();
      expect(sources.entries.single.path, path);
      final entries = await repository.listRecovery(
        sources.entries.single.path,
      );
      final retained = entries.entries.singleWhere((e) => !e.legacy);
      expect(retained.path, p.dirname(proposal.manifestPath));
      final snapshot = await repository.readRecovery(retained);
      expect(snapshot.sourceState, GenerationRecoverySource.unavailable);
      expect(
        snapshot.files
            .singleWhere((f) => f.kind == GenerationRecoveryFileKind.tree)
            .text,
        isNotNull,
      );
      final hidden = Directory(
        p.join(
          root.path,
          '.deleted',
          'Rep',
          '.cap-generation',
          'Other.pgn',
          'run',
        ),
      );
      await hidden.create(recursive: true);
      await Link(p.join(root.path, 'linked')).create(hidden.parent.parent.path);
      expect(
        (await repository.listRecoverySources()).entries.map((s) => s.path),
        [path],
      );
    },
  );

  test(
    'source conflict retains inspectable course/model PGNs across restart and export',
    () async {
      final publisher = GenerationPublicationController(
        documents: documents,
        drafts: StorageGenerationDraftRepository(storage),
      );
      final source = await publisher.begin(path, {'depth': 8});
      await File(path).writeAsString('[Event "External"]\n\n1. d4 *');
      final result = await publisher.publish(
        source,
        games: ['[Event "Proposal"]\n\n1. c4 *'],
        modelGames: '[Event "Model"]\n\n1. Nf3 *',
      );
      expect(result, isA<GenerationPublicationRefused>());
      final repository = reopen();
      final catalog = await repository.listRecovery(path);
      final entry = catalog.entries.singleWhere((e) => !e.legacy);
      final inspected = await GenerationArtifacts(
        repository,
      ).inspectRecovery(entry);
      expect(inspected.snapshot.sourceState, GenerationRecoverySource.changed);
      expect(inspected.snapshot.runId, source.runId);
      expect(inspected.snapshot.config['depth'], 8);
      expect(inspected.snapshot.receipt, GenerationRecoveryReceipt.absent);
      final course = inspected.snapshot.files.singleWhere(
        (f) => f.kind == GenerationRecoveryFileKind.course,
      );
      final expected = await File(
        p.join(p.dirname(result.staged.manifestPath), 'course.pgn'),
      ).readAsBytes();
      await File(
        course.path,
      ).writeAsString('externally edited after inspection');
      final destination = p.join(root.path, 'Recovered.pgn');
      await repository.exportRecovery(course, destination);
      expect(await File(destination).readAsBytes(), expected);
      expect(await File(path).readAsString(), contains('External'));
      await expectLater(
        repository.exportRecovery(course, destination),
        throwsA(
          isA<GenerationArtifactFailure>().having(
            (e) => e.kind,
            'collision',
            GenerationArtifactFailureKind.collision,
          ),
        ),
      );
      final restarted = await reopen().readRecovery(
        (await reopen().listRecovery(
          path,
        )).entries.singleWhere((e) => !e.legacy),
      );
      expect(
        restarted.files
            .singleWhere((f) => f.kind == GenerationRecoveryFileKind.course)
            .text,
        'externally edited after inspection',
      );
    },
  );

  test(
    'a missing receipt after committed PGN is not reported as unpublished',
    () async {
      final publisher = GenerationPublicationController(
        documents: documents,
        drafts: StorageGenerationDraftRepository(
          _InterruptedStorage(root, suffix: 'published.json'),
        ),
      );
      final source = await publisher.begin(path, {});
      final result = await publisher.publish(
        source,
        games: ['[Event "Saved despite receipt failure"]\n\n1. d4 *'],
      );
      expect(result, isA<GenerationPublished>());
      expect((result as GenerationPublished).receiptError, isNotNull);
      final entry = (await reopen().listRecovery(
        path,
      )).entries.singleWhere((e) => !e.legacy);
      final snapshot = await reopen().readRecovery(entry);
      expect(snapshot.receipt, GenerationRecoveryReceipt.absent);
      expect(
        await File(path).readAsString(),
        contains('Saved despite receipt failure'),
      );
      expect(
        snapshot.files
            .singleWhere((f) => f.kind == GenerationRecoveryFileKind.course)
            .bytes,
        await File(path).readAsBytes(),
      );
      await StorageGenerationDraftRepository(
        storage,
      ).recordPublication(result.staged, result.snapshot);
      expect(
        (await reopen().readRecovery(entry)).receipt,
        GenerationRecoveryReceipt.recorded,
      );
    },
  );

  test(
    'selected and retained generations preserve evidence without adopting changed analysis',
    () async {
      final repository = reopen();
      final run = await repository.begin(path, {'depth': 4});
      final first = await repository.prepare(run, legacyRecoveryPayloads());
      await repository.select(run, first);
      final second = await repository.prepare(run, {
        GenerationArtifactKind.probes: '{damaged',
      });
      repository.close(run);
      final entries = (await reopen().listRecovery(
        path,
      )).entries.where((e) => !e.legacy).toList();
      expect(entries, hasLength(2));
      final selected = await reopen().readRecovery(
        entries.singleWhere(
          (e) => e.id == p.basename(p.dirname(first.manifestPath)),
        ),
      );
      expect(selected.namedBySelection, true);
      expect(selected.sourceState, GenerationRecoverySource.matches);
      final otherEntry = entries.singleWhere(
        (e) => e.id == p.basename(p.dirname(second.manifestPath)),
      );
      await File(
        p.join(otherEntry.path, 'tree.json'),
      ).writeAsString('{user edit');
      final other = await GenerationArtifacts(
        reopen(),
      ).inspectRecovery(otherEntry);
      expect(other.snapshot.namedBySelection, false);
      expect(
        other.snapshot.files
            .singleWhere((f) => f.kind == GenerationRecoveryFileKind.tree)
            .integrity,
        GenerationRecoveryIntegrity.changed,
      );
      expect(other.items.where((i) => i.error != null), hasLength(2));
      expect(other.items.any((i) => i.trap != null), true);
      expect((await reopen().read(path)).generationId, selected.entry.id);
      await File(path).writeAsString('1. d4 *');
      expect(
        (await reopen().readRecovery(otherEntry)).sourceState,
        GenerationRecoverySource.changed,
      );
      expect(
        (await reopen().read(path)).origin,
        GenerationArtifactOrigin.stale,
      );
    },
  );

  test(
    'interrupted staging and malformed manifests retain fixed files with isolated failures',
    () async {
      final failing = StorageGenerationArtifactRepository(
        storage: _InterruptedStorage(root),
        documents: documents,
      );
      final run = await failing.begin(path, {});
      await expectLater(
        failing.prepare(run, legacyRecoveryPayloads()),
        throwsA(isA<GenerationArtifactFailure>()),
      );
      final entry = (await reopen().listRecovery(
        path,
      )).entries.singleWhere((e) => !e.legacy);
      final interrupted = await reopen().readRecovery(entry);
      expect(interrupted.files.where((f) => f.error != null), hasLength(4));
      expect(
        interrupted.files
            .singleWhere((f) => f.kind == GenerationRecoveryFileKind.manifest)
            .bytes,
        isNotNull,
      );
      final manifest = File(p.join(entry.path, 'manifest.json'));
      await manifest.writeAsString(
        jsonEncode({
          'version': 1,
          'runId': 'record',
          'source': path,
          'course': '../../outside.pgn',
        }),
      );
      await File(p.join(entry.path, 'course.pgn')).writeAsString('1. c4 *');
      final safe = await reopen().readRecovery(entry);
      expect(
        safe.files
            .singleWhere((f) => f.kind == GenerationRecoveryFileKind.course)
            .text,
        '1. c4 *',
      );
      await manifest.writeAsString('{broken');
      final malformed = await reopen().readRecovery(entry);
      expect(malformed.error?.kind, GenerationArtifactFailureKind.decode);
      expect(
        malformed.files
            .singleWhere((f) => f.kind == GenerationRecoveryFileKind.course)
            .text,
        '1. c4 *',
      );
    },
  );

  test(
    'namespace retry, unsafe run and replaced directory cannot redirect recovery',
    () async {
      final outside = await Directory(p.join(root.path, 'outside')).create();
      final namespace = p.join(root.path, '.cap-generation');
      await Link(namespace).create(outside.path);
      final blocked = await reopen().listRecovery(path);
      expect(blocked.error?.kind, GenerationArtifactFailureKind.enumerate);
      expect(blocked.entries.single.legacy, true);
      await Link(namespace).delete();
      final directory = await Directory(
        p.join(namespace, 'Main.pgn', 'run'),
      ).create(recursive: true);
      await File(p.join(directory.path, 'course.pgn')).writeAsString('1. e4 *');
      await Link(p.join(directory.parent.path, 'unsafe')).create(outside.path);
      final catalog = await reopen().listRecovery(path);
      expect(catalog.error, isNull);
      expect(
        catalog.entries.singleWhere((e) => e.id == 'unsafe').error,
        isNotNull,
      );
      final entry = catalog.entries.singleWhere((e) => e.id == 'run');
      await directory.rename('${directory.path}-old');
      await Directory(directory.path).create();
      await File(p.join(directory.path, 'course.pgn')).writeAsString('1. d4 *');
      await expectLater(
        reopen().readRecovery(entry),
        throwsA(isA<GenerationArtifactFailure>()),
      );
    },
  );
}
