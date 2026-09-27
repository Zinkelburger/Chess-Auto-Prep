import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/generation/controllers/generation_publication_controller.dart';
import 'package:chess_auto_prep/features/generation/models/generation_publication.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/generation/storage_generation_draft_repository.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late File source;
  late NativePgnDocumentStore documents;
  late StorageGenerationDraftRepository drafts;
  const original = '[Event "Source"]\n\n1. e4 e5 *\n';
  const generated = '[Event "Generated"]\n\n1. d4 d5 *\n';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('generation-publication-');
    source = File(p.join(root.path, 'Main.pgn'));
    documents = NativePgnDocumentStore();
    drafts = StorageGenerationDraftRepository(
      IOStorageService(
        documentsRoot: root,
        supportRoot: root,
        repertoiresRoot: root,
      ),
    );
    expect(await documents.create(source.path, original), isA<PgnSaved>());
  });
  tearDown(() => root.delete(recursive: true));

  GenerationPublicationController controller() =>
      GenerationPublicationController(documents: documents, drafts: drafts);

  test(
    'reserved namespace symlink refuses before touching source or its target',
    () async {
      final outside = await Directory.systemTemp.createTemp(
        'generation-outside-',
      );
      addTearDown(() => outside.delete(recursive: true));
      await Link(
        p.join(root.path, StorageGenerationDraftRepository.directoryName),
      ).create(outside.path);
      final owner = controller();
      final run = await owner.begin(source.path, {});
      await expectLater(
        owner.publish(run, games: [generated]),
        throwsA(isA<GenerationStagingFailed>()),
      );
      expect(await source.readAsString(), original);
      expect(await outside.list().toList(), isEmpty);
    },
  );

  test('two independent runs on one source have exactly one winner', () async {
    final first = controller();
    final second = controller();
    final a = await first.begin(source.path, {'maxPly': 4});
    final b = await second.begin(source.path, {'maxPly': 8});
    final outcomes = await Future.wait([
      first.publish(a, games: [generated]),
      second.publish(b, games: [generated]),
    ]);
    expect(outcomes.whereType<GenerationPublished>(), hasLength(1));
    expect(outcomes.whereType<GenerationPublicationRefused>(), hasLength(1));
    expect(await source.readAsString(), '$original\n$generated');
    for (final outcome in outcomes) {
      expect(await File(outcome.staged.manifestPath).exists(), isTrue);
      expect(
        await File(
          p.join(p.dirname(outcome.staged.manifestPath), 'course.pgn'),
        ).readAsString(),
        '$original\n$generated',
      );
    }
  });

  test(
    'same-byte external replacement refuses without touching user files',
    () async {
      final owner = controller();
      final run = await owner.begin(source.path, {});
      final replacement = File(p.join(root.path, 'external.pgn'));
      await replacement.writeAsString(original);
      await replacement.rename(source.path);
      final outcome = await owner.publish(run, games: [generated]);
      expect(outcome, isA<GenerationPublicationRefused>());
      expect(await source.readAsString(), original);
      expect(await File(outcome.staged.manifestPath).exists(), isTrue);
    },
  );

  test('companions survive edits and a fresh owner across restart', () async {
    final owner = controller();
    final run = await owner.begin(source.path, {});
    final first = await owner.publish(
      run,
      games: [generated],
      modelGames: original,
    );
    expect(first, isA<GenerationPublished>());
    final companion = File(first.staged.modelGamesPath!);
    await companion.writeAsString('user annotations');

    final restarted = controller();
    final next = await restarted.begin(source.path, {});
    final second = await restarted.publish(
      next,
      games: const [],
      modelGames: generated,
    );
    expect(second, isA<GenerationPublished>());
    expect(await companion.readAsString(), 'user annotations');
    expect(await File(second.staged.modelGamesPath!).readAsString(), generated);
    final manifest = jsonDecode(
      await File(second.staged.manifestPath).readAsString(),
    );
    expect(
      manifest['baseline']['nativeIdentity'],
      next.snapshot!.revision.nativeIdentity,
    );
    final receipt = jsonDecode(
      await File(
        p.join(p.dirname(second.staged.manifestPath), 'published.json'),
      ).readAsString(),
    );
    final current = await documents.open(source.path) as PgnOpened;
    expect(
      receipt['revision']['nativeIdentity'],
      current.snapshot.revision.nativeIdentity,
    );
  });

  test(
    'recovery output never appears as repertoires or chapter folders',
    () async {
      final owner = controller();
      await owner.publish(
        await owner.begin(source.path, {}),
        games: [generated],
        modelGames: original,
      );
      final storage = IOStorageService(
        documentsRoot: root,
        supportRoot: root,
        repertoiresRoot: root,
      );
      expect(await storage.listSubdirectories(root.path), isEmpty);
      final repertoires = await storage.listRepertoires();
      expect(
        repertoires.map((entry) => entry.name),
        isNot(contains(StorageGenerationDraftRepository.directoryName)),
      );
    },
  );
}
