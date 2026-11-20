import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/trainer/trainer.dart';
import 'package:chess_auto_prep/features/trainer/trainer_state.dart';
import 'package:chess_auto_prep/features/trainer/training_scope.dart';
import 'package:chess_auto_prep/features/trainer/training_selection.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/document_repository.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/book/repertoire_catalog.dart';
import 'package:chess_auto_prep/workspace/document/document_saver.dart';
import 'package:chess_auto_prep/workspace/document/document_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/books_fixture.dart';
import '../../support/scripted_files.dart';
import '../../support/scripted_progress.dart';
import '../../support/scripted_store.dart';

const _text = '// Color: White\n[Event "Line"]\n\n1. e4 e5 *';

void main() {
  late ScriptedDocumentStore store;
  late DocumentRepository documents;
  late ScriptedFiles files;
  late RepertoireCatalog catalog;
  late SettingsStore settings;
  late TrainingSelection selection;

  setUp(() async {
    store = ScriptedDocumentStore();
    for (final name in ['Main', 'Other']) {
      store.documents[ref('KID', name)] = Opened(
        _text,
        scriptedRevision(_text),
      );
    }
    documents = DocumentRepository(store);
    files = ScriptedFiles(
      listing: Repertoires([
        folder('KID', ['Main', 'Other']),
      ]),
    );
    catalog = RepertoireCatalog(
      files: files,
      documents: documents,
      root: '/repertoires',
    );
    await catalog.refresh();
    settings = SettingsStore();
    selection = TrainingSelection(catalog, settings);
    selection.choose(catalog.repertoires.single);
  });

  tearDown(() {
    selection.dispose();
    settings.dispose();
    catalog.dispose();
    documents.dispose();
  });

  test(
    'marking the open top-level PGN as learned leaves its sibling new',
    () async {
      final repertoires = [
        for (final name in ['A', 'B'])
          RepertoireFolder(
            name: name,
            path: '/repertoires/$name.pgn',
            modified: DateTime.utc(2026),
            chapters: [
              ChapterRef(
                repertoire: name,
                name: name,
                path: '/repertoires/$name.pgn',
              ),
            ],
          ),
      ];
      files.listing = Repertoires(repertoires);
      for (final repertoire in repertoires) {
        store.documents[repertoire.chapters.single] = Opened(
          _text,
          scriptedRevision(_text),
        );
      }
      await catalog.refresh();
      final saver = DocumentSaver(store);
      addTearDown(saver.dispose);
      final session = DocumentSession(store, saver);
      addTearDown(session.dispose);
      final a = repertoires.first;
      await session.open(a.chapters.single);
      final analysis = EngineAnalysis(
        session,
        () async => const StartFailed('test'),
      );
      addTearDown(analysis.dispose);
      final books = booksWith();
      addTearDown(books.dispose);
      final progress = ScriptedProgress();
      final trainer = Trainer(
        session: session,
        chapters: ScopeReader(files: files, documents: store),
        files: progress,
        analysis: analysis,
        catalog: catalog,
        time: (now: () => DateTime.utc(2026), jitter: () => 0),
        books: books,
      );
      addTearDown(trainer.dispose);

      trainer.selection.enter(session.source);
      await trainer.reload();
      final ready = trainer.state as TrainerReady;
      await ready.progress.mark(trainer.scopeLines, known: true);
      final learned = progress.reviews.values.where((row) => !row.untrained);
      expect(learned.map((row) => row.key.source), [a.path]);

      trainer.selection.choose(a);
      await trainer.reload();
      expect(trainer.scopeLines.map((line) => line.key.source), [a.path]);
    },
  );

  test(
    'a renamed repertoire stays the trainer\'s choice, pauses and all',
    () async {
      selection.pauseScope(true, chapter: ref('KID', 'Other'));
      expect(selection.chapterPaused(ref('KID', 'Other')), isTrue);

      files.listing = Repertoires([
        folder('King\'s Indian', ['Main', 'Other']),
      ]);
      await documents.moveFolder(
        '/repertoires/KID',
        '/repertoires/King\'s Indian',
      );
      await catalog.synchronize();

      expect(selection.root, '/repertoires/King\'s Indian');
      expect(selection.repertoire?.name, 'King\'s Indian');
      expect(
        settings.value.training.repertoirePath,
        '/repertoires/King\'s Indian',
      );
      expect(
        selection.chapterPaused(ref('King\'s Indian', 'Other')),
        isTrue,
        reason: 'a paused chapter stays paused under its new folder',
      );
      expect(selection.chapterPaused(ref('King\'s Indian', 'Main')), isFalse);
    },
  );

  test('a paused chapter renamed or moved stays paused', () async {
    selection.pauseScope(true, chapter: ref('KID', 'Other'));
    final other = ref('KID', 'Other');
    await documents.move(
      other,
      ref('KID', 'Sämisch'),
      expected: scriptedRevision(_text),
    );
    await catalog.synchronize();

    expect(selection.chapterPaused(ref('KID', 'Sämisch')), isTrue);
    expect(selection.root, '/repertoires/KID');
  });

  test('a paused repertoire renamed stays paused', () async {
    selection.pauseScope(true);
    await documents.moveFolder('/repertoires/KID', '/repertoires/Benoni');
    await catalog.synchronize();

    expect(selection.root, '/repertoires/Benoni');
    expect(selection.repertoirePaused, isTrue);
  });
}
