import 'dart:async';
import 'dart:convert';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/generation/controllers/generation_publication_controller.dart';
import 'package:chess_auto_prep/features/generation/models/generation_publication.dart';
import 'package:chess_auto_prep/infrastructure/generation/storage_generation_draft_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../core/fake_storage.dart';
import '../../support/scripted_document_store.dart';

class _Storage extends MemoryStorage {
  Future<void> Function(String)? beforeWrite;

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    await beforeWrite?.call(path);
    await super.writeFile(
      path,
      content,
      createOnly: createOnly,
      expectedContent: expectedContent,
    );
  }
}

void main() {
  late Store documents;
  late _Storage storage;
  late GenerationPublicationController publication;

  setUp(() {
    documents = Store();
    storage = _Storage();
    publication = GenerationPublicationController(
      documents: documents,
      drafts: StorageGenerationDraftRepository(
        storage,
        prepareDirectory: (_) async {},
      ),
    );
  });

  Future<GenerationSource> begin() =>
      publication.begin('/main.pgn', {'maxPly': 12});

  test(
    'captured config is deeply immutable and detached from caller settings',
    () async {
      final config = <String, dynamic>{
        'sources': ['one.pgn'],
        'skeleton': {
          'moves': ['e4'],
        },
      };
      final opened = Completer<PgnOpenResult>();
      documents.onOpen = (_) => opened.future;
      final pending = publication.begin('/main.pgn', config);
      (config['sources'] as List).add('later.pgn');
      ((config['skeleton'] as Map)['moves'] as List).add('e5');
      opened.complete(PgnOpened(documents.current));
      final source = await pending;
      expect(source.config['sources'], ['one.pgn']);
      expect((source.config['skeleton'] as Map)['moves'], ['e4']);
      expect(
        () => (source.config['sources'] as List).add('mutated'),
        throwsUnsupportedError,
      );
      expect(
        () => (source.config['skeleton'] as Map)['new'] = true,
        throwsUnsupportedError,
      );
    },
  );

  test(
    'a reconstructed source with the same run id has no publication capability',
    () async {
      final source = await begin();
      final reconstructed = GenerationSource(
        runId: source.runId,
        path: '/other.pgn',
        snapshot: null,
        config: source.config,
      );
      await expectLater(
        publication.publish(reconstructed, games: ['wrong source']),
        throwsStateError,
      );
      expect(documents.creates, isEmpty);
      expect(
        await publication.publish(source, games: ['right source']),
        isA<GenerationPublished>(),
      );
    },
  );

  test(
    'stages source, run/config identity and companion before one commit',
    () async {
      final source = await begin();
      documents.onSave = (baseline, content) async {
        expect(
          storage.files.keys.where((p) => p.endsWith('course.pgn')),
          hasLength(1),
        );
        expect(
          storage.files.keys.where((p) => p.endsWith('model_games.pgn')),
          hasLength(1),
        );
        expect(baseline.revision, source.snapshot!.revision);
        return PgnSaved(before: baseline, after: snapshot(content));
      };
      final result = await publication.publish(
        source,
        games: ['1. e4 *', '1. d4 *'],
        modelGames: '1. c4 e5 *',
      );
      expect(result, isA<GenerationPublished>());
      expect(documents.saves, hasLength(1));
      final manifest = jsonDecode(storage.files[result.staged.manifestPath]!);
      expect(manifest['runId'], source.runId);
      expect(manifest['baseline']['nativeIdentity'], '1');
      expect(manifest['config'], {'maxPly': 12});
      expect(storage.files[result.staged.modelGamesPath], '1. c4 e5 *');
      expect(storage.files.values, contains('original\n1. e4 *\n1. d4 *'));
      expect(
        storage.files.keys.where((p) => p.endsWith('published.json')),
        hasLength(1),
      );
    },
  );

  test(
    'external source edit refuses without losing the generated proposal',
    () async {
      final source = await begin();
      documents.current = snapshot('user revision', revision: '2');
      final result = await publication.publish(source, games: ['generated']);
      expect(result, isA<GenerationPublicationRefused>());
      expect(documents.current.content, 'user revision');
      expect(storage.files.values, contains('original\ngenerated'));
      expect(
        storage.files.keys.any((p) => p.endsWith('published.json')),
        isFalse,
      );
    },
  );

  test(
    'same text with another native identity refuses stale completion',
    () async {
      final source = await begin();
      documents.current = snapshot('original', revision: 'replacement');
      expect(
        await publication.publish(source, games: ['generated']),
        isA<GenerationPublicationRefused>(),
      );
      expect(documents.current.content, 'original');
    },
  );

  test(
    'new source uses create-only and refuses a concurrent creator',
    () async {
      documents.onOpen = (_) async => const PgnMissing();
      final source = await begin();
      documents.onCreate = (_, _) async => const PgnNameCollision();
      final result = await publication.publish(source, games: ['generated']);
      expect(result, isA<GenerationPublicationRefused>());
      expect(documents.creates, ['/main.pgn']);
      expect(documents.saves, isEmpty);
    },
  );

  test('unreadable source cannot be treated as a new chapter', () async {
    documents.onOpen = (_) async => PgnReadFailed(StateError('read failed'));
    await expectLater(begin(), throwsStateError);
    expect(documents.creates, isEmpty);
    expect(storage.files, isEmpty);
    documents.onOpen = null;
    expect(await begin(), isA<GenerationSource>());
  });

  test(
    'regeneration and no-model runs preserve every edited companion',
    () async {
      storage.files['/main_model_games.pgn'] = 'edited legacy companion';
      final first = await publication.publish(
        await begin(),
        games: ['first'],
        modelGames: 'first model',
      );
      storage.files[first.staged.modelGamesPath!] =
          'edited generated companion';
      final second = await publication.publish(
        await begin(),
        games: ['second'],
        modelGames: 'second model',
      );
      final third = await publication.publish(await begin(), games: ['third']);
      expect(second.staged.modelGamesPath, isNot(first.staged.modelGamesPath));
      expect(third.staged.modelGamesPath, isNull);
      expect(storage.files['/main_model_games.pgn'], 'edited legacy companion');
      expect(
        storage.files[first.staged.modelGamesPath],
        'edited generated companion',
      );
      expect(storage.files[second.staged.modelGamesPath], 'second model');
    },
  );

  test('interruption while staging never commits a partial source', () async {
    storage.beforeWrite = (path) async {
      if (path.endsWith('model_games.pgn')) throw StateError('disk full');
    };
    final source = await begin();
    await expectLater(
      publication.publish(source, games: ['generated'], modelGames: 'model'),
      throwsA(isA<GenerationStagingFailed>()),
    );
    expect(documents.saves, isEmpty);
    expect(storage.files.values, contains('original\ngenerated'));
    expect(
      storage.files.keys.where((p) => p.endsWith('manifest.json')),
      hasLength(1),
    );
    await expectLater(
      publication.publish(source, games: ['retry']),
      throwsStateError,
    );
  });

  test(
    'uncertain native commit is single-use and retains all recovery output',
    () async {
      final source = await begin();
      documents.onSave = (baseline, content) async => PgnWriteUncertain(
        error: StateError('receipt interrupted'),
        before: baseline,
        observed: snapshot(content),
      );
      final result = await publication.publish(source, games: ['generated']);
      expect(result, isA<GenerationPublicationUncertain>());
      expect(storage.files.values, contains('original\ngenerated'));
      await expectLater(
        publication.publish(source, games: ['generated']),
        throwsStateError,
      );
      expect(documents.saves, hasLength(1));
    },
  );

  test(
    'receipt failure reports committed source and never repeats append',
    () async {
      storage.beforeWrite = (path) async {
        if (path.endsWith('published.json')) throw StateError('receipt failed');
      };
      final source = await begin();
      final result = await publication.publish(source, games: ['generated']);
      expect(result, isA<GenerationPublished>());
      expect((result as GenerationPublished).receiptError, isA<StateError>());
      expect(documents.current.content, 'original\ngenerated');
      await expectLater(
        publication.publish(source, games: ['generated']),
        throwsStateError,
      );
      expect(documents.saves, hasLength(1));
    },
  );

  test(
    'duplicate starts and concurrent publication cannot create duplicate jobs',
    () async {
      final staged = Completer<void>();
      final release = Completer<void>();
      storage.beforeWrite = (path) async {
        if (path.endsWith('course.pgn')) {
          staged.complete();
          await release.future;
        }
      };
      final source = await begin();
      await expectLater(begin(), throwsStateError);
      final pending = publication.publish(source, games: ['generated']);
      await staged.future;
      await expectLater(
        publication.publish(source, games: ['duplicate']),
        throwsStateError,
      );
      release.complete();
      expect(await pending, isA<GenerationPublished>());
      expect(documents.saves, hasLength(1));
    },
  );

  test(
    'cancellation during staging preserves draft but never publishes',
    () async {
      final staged = Completer<void>();
      final release = Completer<void>();
      storage.beforeWrite = (path) async {
        if (path.endsWith('course.pgn')) {
          staged.complete();
          await release.future;
        }
      };
      final source = await begin();
      final pending = publication.publish(source, games: ['generated']);
      await staged.future;
      publication.cancel();
      await expectLater(begin(), throwsStateError);
      release.complete();
      expect(await pending, isA<GenerationPublicationRefused>());
      expect(documents.saves, isEmpty);
      expect(storage.files.values, contains('original\ngenerated'));
      expect(await begin(), isA<GenerationSource>());
    },
  );
  test(
    'no new lines validates the source without changing its editor revision',
    () async {
      final source = await begin();
      final result = await publication.publish(
        source,
        games: const [],
        modelGames: 'model',
      );
      expect(result, isA<GenerationPublished>());
      expect(
        (result as GenerationPublished).snapshot.revision,
        source.snapshot!.revision,
      );
      expect(documents.saves, isEmpty);
      expect(storage.files[result.staged.modelGamesPath], 'model');
      final next = await begin();
      documents.current = snapshot('original', revision: 'replaced');
      expect(
        await publication.publish(next, games: const []),
        isA<GenerationPublicationRefused>(),
      );
      expect(documents.saves, isEmpty);
    },
  );
}
