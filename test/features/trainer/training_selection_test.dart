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
  group('entering the trainer', () {
    late SettingsStore fresh;
    late TrainingSelection entering;

    setUp(() {
      fresh = SettingsStore();
      entering = TrainingSelection(catalog, fresh);
    });

    tearDown(() {
      entering.dispose();
      fresh.dispose();
    });

    test('a new selection shows every line, choosing none', () {
      expect(entering.active, isFalse);
      expect(entering.choosing, isFalse);
    });

    test('takes the repertoire of the chapter on the board and remembers '
        'it, leaving line choosing off', () {
      entering.chooseLines(true);
      entering.enter(ref('KID', 'Main'));

      expect(entering.active, isTrue);
      expect(entering.root, '/repertoires/KID');
      expect(entering.choosing, isFalse);
      expect(fresh.value.training.repertoirePath, '/repertoires/KID');
    });

    test('with nothing on the board, the only repertoire is the choice', () {
      entering.enter(null);

      expect(entering.root, '/repertoires/KID');
      expect(entering.repertoire?.name, 'KID');
    });
  });

  test('choosing a repertoire ends choosing lines', () {
    selection.chooseLines(true);
    selection.choose(catalog.repertoires.single);
    expect(selection.choosing, isFalse);
  });

  group('following the document', () {
    test('leaves the trainer\'s own browsing', () {
      selection.select(chapter: ref('KID', 'Main'));
      selection.followDocument();

      expect(selection.active, isFalse);
      expect(selection.chapter, isNull);
    });

    test('ends choosing lines, which would hide every line from the other '
        'Train tabs', () {
      final idle = TrainingSelection(catalog, null);
      addTearDown(idle.dispose);
      idle.chooseLines(true);
      idle.followDocument();
      expect(idle.choosing, isFalse);
    });

    test('says nothing when the trainer was not browsing', () {
      final idle = TrainingSelection(catalog, null);
      addTearDown(idle.dispose);
      var heard = 0;
      idle.addListener(() => heard++);
      idle.followDocument();
      expect(heard, 0);
    });
  });

  group('a chapter renamed inside the chosen repertoire', () {
    final other = ref('KID', 'Other');
    final renamed = ref('KID', 'Sämisch');

    Future<int> rename() async {
      var heard = 0;
      selection.addListener(() => heard++);
      await documents.move(other, renamed, expected: scriptedRevision(_text));
      await catalog.synchronize();
      return heard;
    }

    test('changes nothing shown when nothing of it was selected', () async {
      selection.select(chapter: ref('KID', 'Main'));
      expect(await rename(), 0);
      expect(selection.chapter?.path, ref('KID', 'Main').path);
    });

    test('takes the selected chapter along', () async {
      selection.select(chapter: other);
      expect(await rename(), greaterThan(0));
      expect(selection.chapter?.path, renamed.path);
    });

    test('takes the selected line along', () async {
      selection.select(line: (source: other.path, id: 'x'));
      expect(await rename(), greaterThan(0));
      expect(selection.line, (source: renamed.path, id: 'x'));
    });

    test('takes the picked lines along', () async {
      selection.chooseLines(true);
      selection.pick((source: other.path, id: 'x'), true);
      expect(await rename(), greaterThan(0));
      expect(selection.picked, {(source: renamed.path, id: 'x')});
    });
  });
}
