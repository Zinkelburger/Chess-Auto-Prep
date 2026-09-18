import 'dart:io';
import 'dart:convert';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_document_store.dart';
import 'package:chess_auto_prep/features/generation/models/generation_artifacts.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/generation/storage_generation_artifact_repository.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _Storage extends IOStorageService {
  _Storage(Directory root) : super(documentsRoot: root, supportRoot: root);
  String? failSuffix;
  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (failSuffix != null && path.endsWith(failSuffix!)) {
      throw const FileSystemException('injected interruption');
    }
    await super.writeFile(
      path,
      content,
      createOnly: createOnly,
      expectedContent: expectedContent,
    );
  }
}

class _Documents implements PgnDocumentStore {
  _Documents(this.delegate);
  final PgnDocumentStore delegate;
  @override
  bool get supportsQuarantine => delegate.supportsQuarantine;
  @override
  Future<PgnQuarantineResult> quarantine(
    PgnSnapshot baseline, {
    String? allowedRoot,
  }) => delegate.quarantine(baseline, allowedRoot: allowedRoot);
  bool uncertain = false;
  int pointerWrites = 0;
  Future<void> Function(String)? beforeOpen;
  @override
  Future<PgnOpenResult> open(String path) async {
    await beforeOpen?.call(path);
    return delegate.open(path);
  }

  @override
  Future<PgnWriteResult> create(String path, String content) =>
      delegate.create(path, content);
  @override
  Future<PgnWriteResult> save(PgnSnapshot before, String content) async {
    final result = await delegate.save(before, content);
    if (before.path.endsWith('artifacts.current.json')) {
      pointerWrites++;
      if (uncertain && result is PgnSaved) {
        return PgnWriteUncertain(
          error: StateError('receipt unavailable'),
          before: before,
          observed: result.after,
        );
      }
    }
    return result;
  }
}

void main() {
  late Directory directory;
  late String path;
  late _Documents documents;
  late _Storage storage;
  late StorageGenerationArtifactRepository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('artifact-generations-');
    path = p.join(directory.path, 'Main.pgn');
    documents = _Documents(NativePgnDocumentStore());
    storage = _Storage(directory);
    await documents.create(path, '[Event "Original"]\n\n1. e4 e5 *\n');
    repository = StorageGenerationArtifactRepository(
      storage: storage,
      documents: documents,
    );
  });
  tearDown(() => directory.delete(recursive: true));
  Future<GenerationArtifactProposal> publish(
    GenerationArtifactRun run,
    Map<GenerationArtifactKind, String?> changes,
  ) async {
    final proposal = await repository.prepare(run, changes);
    await repository.select(run, proposal);
    return proposal;
  }

  test('generate then reopen selects one complete immutable bundle', () async {
    final run = await repository.begin(path, {'depth': 12});
    await publish(run, {
      GenerationArtifactKind.tree: 'tree',
      GenerationArtifactKind.traps: 'traps',
    });
    repository.close(run);
    final loaded = await repository.read(path);
    expect(loaded.origin, GenerationArtifactOrigin.current);
    expect(loaded.payloads, {
      GenerationArtifactKind.tree: 'tree',
      GenerationArtifactKind.traps: 'traps',
    });
  });

  test(
    'partial/probe generations retain the selected database and old bytes',
    () async {
      final run = await repository.begin(path, {'depth': 12});
      final first = await publish(run, {GenerationArtifactKind.tree: 'tree'});
      await publish(run, {GenerationArtifactKind.partial: 'partial'});
      await publish(run, {GenerationArtifactKind.probes: 'probes'});
      expect((await repository.read(path)).payloads, {
        GenerationArtifactKind.tree: 'tree',
        GenerationArtifactKind.partial: 'partial',
        GenerationArtifactKind.probes: 'probes',
      });
      await publish(run, {GenerationArtifactKind.partial: null});
      expect(
        (await repository.read(
          path,
        )).payloads.containsKey(GenerationArtifactKind.partial),
        isFalse,
      );
      expect(
        await File(
          p.join(p.dirname(first.manifestPath), 'tree.json'),
        ).readAsString(),
        'tree',
      );
    },
  );

  test(
    'interrupted proposal leaves current generation valid and recoverable bytes',
    () async {
      final run = await repository.begin(path, {});
      final first = await publish(run, {GenerationArtifactKind.tree: 'valid'});
      final proposal = await repository.prepare(run, {
        GenerationArtifactKind.tree: 'next',
      });
      repository.close(run);
      expect(
        (await repository.read(path)).payloads[GenerationArtifactKind.tree],
        'valid',
      );
      expect(await File(proposal.manifestPath).exists(), isTrue);
      await expectLater(
        repository.select(run, proposal),
        throwsA(isA<GenerationArtifactFailure>()),
      );
      expect(await File(first.manifestPath).exists(), isTrue);
    },
  );

  test(
    'late completion cannot replace another run selected after its start',
    () async {
      final seed = await repository.begin(path, {});
      await publish(seed, {GenerationArtifactKind.tree: 'initial'});
      repository.close(seed);
      final older = await repository.begin(path, {});
      final newer = await repository.begin(path, {});
      final oldProposal = await repository.prepare(older, {
        GenerationArtifactKind.tree: 'old',
      });
      await publish(newer, {GenerationArtifactKind.tree: 'new'});
      await expectLater(
        repository.select(older, oldProposal),
        throwsA(isA<GenerationArtifactFailure>()),
      );
      expect(
        (await repository.read(path)).payloads[GenerationArtifactKind.tree],
        'new',
      );
      expect(await File(oldProposal.manifestPath).exists(), isTrue);
    },
  );

  test(
    'external source replacement invalidates selection even with identical bytes',
    () async {
      final run = await repository.begin(path, {});
      await publish(run, {GenerationArtifactKind.tree: 'tree'});
      final proposal = await repository.prepare(run, {
        GenerationArtifactKind.tree: 'next',
      });
      final replacement = File('$path.replacement');
      await replacement.writeAsString(await File(path).readAsString());
      await replacement.rename(path);
      await expectLater(
        repository.select(run, proposal),
        throwsA(isA<GenerationArtifactFailure>()),
      );
      expect(
        (await repository.read(path)).origin,
        GenerationArtifactOrigin.stale,
      );
    },
  );

  test('edited artifacts are retained and never silently adopted', () async {
    final run = await repository.begin(path, {});
    final old = await publish(run, {GenerationArtifactKind.tree: 'tree'});
    final artifact = File(p.join(p.dirname(old.manifestPath), 'tree.json'));
    await artifact.writeAsString('user edit');
    expect(
      (await repository.read(path)).origin,
      GenerationArtifactOrigin.stale,
    );
    final next = await repository.begin(path, {});
    await publish(next, {GenerationArtifactKind.tree: 'new tree'});
    expect(await artifact.readAsString(), 'user edit');
    expect(
      (await repository.read(path)).payloads[GenerationArtifactKind.tree],
      'new tree',
    );
  });

  test(
    'legacy reads are explicit and cannot seed a new authoritative generation',
    () async {
      final legacy = File('${p.withoutExtension(path)}_tree.json');
      await legacy.writeAsString('legacy');
      expect(
        (await repository.read(path)).origin,
        GenerationArtifactOrigin.absent,
      );
      expect(
        (await repository.readRecovery(
          (await repository.listRecovery(path)).entries.first,
        )).entry.legacy,
        true,
      );
      final run = await repository.begin(path, {});
      await publish(run, {GenerationArtifactKind.probes: 'fresh probe'});
      expect(
        (await repository.read(
          path,
        )).payloads.containsKey(GenerationArtifactKind.tree),
        isFalse,
      );
      expect(await legacy.readAsString(), 'legacy');
    },
  );

  test(
    'full PGN publication selects prepared artifacts against its exact receipt',
    () async {
      final run = await repository.begin(path, {});
      final proposal = await repository.prepare(run, {
        GenerationArtifactKind.tree: 'tree',
      });
      final before = (await documents.open(path) as PgnOpened).snapshot;
      final saved =
          await documents.save(before, '${before.content}\n1. d4 d5 *\n')
              as PgnSaved;
      await repository.select(run, proposal, publishedSource: saved.after);
      expect(
        (await repository.read(path)).origin,
        GenerationArtifactOrigin.current,
      );
    },
  );

  test(
    'namespace symlink fails closed without writing outside the source',
    () async {
      final elsewhere = await Directory.systemTemp.createTemp(
        'artifact-outside-',
      );
      addTearDown(() => elsewhere.delete(recursive: true));
      await Link(
        p.join(directory.path, '.cap-generation'),
      ).create(elsewhere.path);
      await expectLater(
        repository.begin(path, {}),
        throwsA(isA<GenerationArtifactFailure>()),
      );
      expect(await elsewhere.list().toList(), isEmpty);
    },
  );
  test(
    'interrupted payload staging retains current bundle and the partial proposal',
    () async {
      final run = await repository.begin(path, {});
      await publish(run, {GenerationArtifactKind.tree: 'valid'});
      final before = (await repository.read(path)).generationId;
      storage.failSuffix = 'probes.json';
      GenerationArtifactFailure? failure;
      try {
        await repository.prepare(run, {
          GenerationArtifactKind.probes: 'new probe',
        });
      } on GenerationArtifactFailure catch (error) {
        failure = error;
      }
      expect(failure, isNotNull);
      expect(await File(failure!.proposalPath!).exists(), isTrue);
      expect((await repository.read(path)).generationId, before);
    },
  );

  test('uncertain pointer commit is never replayed by the same run', () async {
    final run = await repository.begin(path, {});
    await publish(run, {GenerationArtifactKind.tree: 'valid'});
    final proposal = await repository.prepare(run, {
      GenerationArtifactKind.tree: 'next',
    });
    documents.uncertain = true;
    await expectLater(
      repository.select(run, proposal),
      throwsA(isA<GenerationArtifactFailure>()),
    );
    expect(documents.pointerWrites, 1);
    expect(
      (await repository.read(path)).payloads[GenerationArtifactKind.tree],
      'next',
    );
    await expectLater(
      repository.select(run, proposal),
      throwsA(isA<GenerationArtifactFailure>()),
    );
    await expectLater(
      repository.prepare(run, {}),
      throwsA(isA<GenerationArtifactFailure>()),
    );
    expect(documents.pointerWrites, 1);
    expect(await File(proposal.manifestPath).exists(), isTrue);
  });

  test(
    'a captured partial card cannot resume or discard a newer generation',
    () async {
      final run = await repository.begin(path, {});
      await publish(run, {GenerationArtifactKind.partial: 'first'});
      final old = (await repository.read(path)).generationId!;
      await publish(run, {GenerationArtifactKind.partial: 'second'});
      await expectLater(
        repository.begin(path, {}, expectedGenerationId: old),
        throwsA(isA<GenerationArtifactFailure>()),
      );
      expect(
        (await repository.read(path)).payloads[GenerationArtifactKind.partial],
        'second',
      );
    },
  );

  test(
    'nested config is captured before the first asynchronous source read',
    () async {
      final values = [1];
      final config = <String, dynamic>{
        'nested': {'values': values},
      };
      final pending = repository.begin(path, config);
      values.add(2);
      final run = await pending;
      final proposal = await repository.prepare(run, {
        GenerationArtifactKind.tree: 'tree',
      });
      final manifest =
          jsonDecode(await File(proposal.manifestPath).readAsString())
              as Map<String, dynamic>;
      expect(manifest['config'], {
        'nested': {
          'values': [1],
        },
      });
    },
  );

  test(
    'source changed during payload loading is rejected before adoption',
    () async {
      final run = await repository.begin(path, {});
      await publish(run, {GenerationArtifactKind.tree: 'tree'});
      var reads = 0;
      documents.beforeOpen = (opened) async {
        if (opened == path && ++reads == 2) {
          await File(path).writeAsString('[Event "Changed"]\n\n1. c4 *');
        }
      };
      expect(
        (await repository.read(path)).origin,
        GenerationArtifactOrigin.stale,
      );
    },
  );
}
