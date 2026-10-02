import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/features/library/library_state.dart';
import 'package:chess_auto_prep/features/trainer/trainer.dart';
import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/repertoire_tree.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/window_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'retained training follows its origin when the detour file changes',
    () async {
      final app = WindowFixture();
      addTearDown(app.dispose);
      await app.library.refresh();
      await app.session.open(kidMain);
      await app.lineTrainer.reload();
      app.lineTrainer.learn();
      final lesson = app.lineTrainer.lesson!;
      await app.session.open(benkoMain);
      expect(lesson.suspended, isTrue);
      expect(
        await app.library.renameChapter(benkoMain, 'Detour'),
        isA<LibraryDone>(),
      );
      await pumpEventQueue();
      expect(app.lineTrainer.lesson, same(lesson));
      expect(
        await app.library.renameChapter(kidMain, 'Origin'),
        isA<LibraryDone>(),
      );
      await pumpEventQueue();
      expect(
        app.lineTrainer.lesson,
        isNull,
        reason: 'the training source changed',
      );
    },
  );

  test(
    'a sibling section rename refreshes training and nested outline membership',
    () async {
      final app = WindowFixture();
      addTearDown(app.dispose);
      const path = '/repertoires/KID/Week 1/Course.pgn';
      const text =
          '// Color: White\n\n[Event "Italian"]\n[ChapterName "A"]\n\n1. e4 e5 *\n\n'
          '[Event "Alapin"]\n[ChapterName "B"]\n\n1. e4 c5 *\n';
      final a = ChapterRef.at(path, section: 'A');
      final b = ChapterRef.at(path, section: 'B');
      final c = ChapterRef.at(path, section: 'C');
      app.store.documents[a.wholeFile] = Opened(text, scriptedRevision(text));
      void listed(List<ChapterRef> chapters) {
        app.chapterFiles.listing = Repertoires([
          RepertoireFolder(
            name: 'KID',
            path: '/repertoires/KID',
            modified: DateTime(2026),
            chapters: chapters,
          ),
        ]);
      }

      listed([a, b]);
      await app.library.refresh();
      await app.session.open(a);
      expect(app.outline.repertoire?.name, 'KID');
      expect(app.outline.chapters, hasLength(2));
      app.lineTrainer.setScope(TrainScope.repertoire);
      await app.lineTrainer.reload();
      listed([a, c]);
      expect(await app.library.renameChapter(b, 'C'), isA<LibraryDone>());
      await app.saver.flush();
      await app.parts.catalog.synchronize();
      await pumpEventQueue();
      expect(app.session.source, a);
      expect(
        (app.lineTrainer.state as TrainerReady).chapters.map(
          (chapter) => chapter.ref.section,
        ),
        ['A', 'C'],
      );
    },
  );

  test(
    'inactive chapter rename and deletion propagate to repertoire training',
    () async {
      final app = WindowFixture();
      addTearDown(app.dispose);
      final b = ChapterRef.at('/repertoires/KID/B.pgn');
      final renamed = ChapterRef.at('/repertoires/KID/Renamed.pgn');
      app.store.documents[b] = Opened(
        blackChapter,
        scriptedRevision(blackChapter),
      );
      void listing(List<ChapterRef> chapters) {
        app.chapterFiles.listing = Repertoires([
          RepertoireFolder(
            name: 'KID',
            path: '/repertoires/KID',
            modified: DateTime(2026),
            chapters: chapters,
          ),
        ]);
      }

      listing([kidMain, b]);
      await app.library.refresh();
      await app.session.open(kidMain);
      app.lineTrainer.setScope(TrainScope.repertoire);
      await app.lineTrainer.reload();
      List<String> sources() => (app.lineTrainer.state as TrainerReady).chapters
          .map((chapter) => chapter.ref.path)
          .toList();
      expect(sources(), [kidMain.path, b.path]);

      listing([kidMain, renamed]);
      expect(await app.library.renameChapter(b, 'Renamed'), isA<LibraryDone>());
      await pumpEventQueue();
      expect(
        app.session.source,
        kidMain,
        reason: 'the active document did not change',
      );
      expect(sources(), [kidMain.path, renamed.path]);

      listing([kidMain]);
      expect(await app.library.deleteChapter(renamed), isA<LibraryDone>());
      await pumpEventQueue();
      expect(sources(), [kidMain.path]);
    },
  );

  group('the shelf holds every book, not only the active one', () {
    const najdorfText =
        '// Color: Black\n\n[Event "Najdorf"]\n[Result "*"]\n\n1. e4 c5 *\n';
    final najdorf = ref('Club', 'Najdorf');
    final dragon = ref('Club', 'Dragon');
    // After 1.e4 c5 2.Nf3, Black to move.
    const afterNf3 =
        'rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';

    /// The fixture's book ('test': benko and KID) in use, and a second
    /// book holding only the Club folder, whose chapters it does not read.
    Future<(WindowFixture, Book)> start(List<String> club) async {
      final app = WindowFixture();
      addTearDown(app.dispose);
      app.store.documents[najdorf] = Opened(
        najdorfText,
        scriptedRevision(najdorfText),
      );
      app.chapterFiles.listing = Repertoires([
        folder('benko', ['Main']),
        folder('KID', ['Main']),
        folder('Club', club),
      ]);
      await app.parts.books.load();
      await app.library.refresh();
      final clubBook = app.parts.books.create('Club book')!;
      app.parts.books.setRepertoire(clubBook, folder('Club', club), true);
      await pumpEventQueue();
      expect(app.parts.books.active?.id, 'test');
      await app.session.open(kidMain);
      app.tree.watch();
      await pumpEventQueue();
      expect(app.tree.state, isNot(isA<TreeReading>()));
      expect(app.shelf.version, greaterThan(0));
      expect(app.shelf.indexOf(najdorf), isNotNull);
      return (app, app.parts.books.books.last);
    }

    test(
      'an edit to another book is read when that book is taken up',
      () async {
        final (app, clubBook) = await start(['Najdorf']);
        await app.session.open(najdorf);
        app.session.toEnd();
        app.session.playMove('g1f3');
        app.session.playMove('d7d6');
        await app.saver.flush();
        expect(app.store.documents[najdorf], isA<Opened>());
        expect(
          (app.store.documents[najdorf]! as Opened).text,
          contains('2. Nf3 d6'),
        );
        await app.parts.catalog.synchronize();
        await pumpEventQueue();
        await app.session.open(kidMain);
        app.parts.books.activate(clubBook);
        await pumpEventQueue();
        final moves = app.shelf
            .indexOf(najdorf)
            ?.movesAt(const Fen(afterNf3).position);
        expect(moves?.keys, contains('d7d6'));
      },
    );

    test('a chapter added to another book is listed when that book is '
        'taken up', () async {
      final (app, clubBook) = await start(['Najdorf']);
      app.chapterFiles.listing = Repertoires([
        folder('benko', ['Main']),
        folder('KID', ['Main']),
        folder('Club', ['Najdorf', 'Dragon']),
      ]);
      expect(
        await app.library.createChapter(folder('Club', ['Najdorf']), 'Dragon'),
        isA<LibraryDone>(),
      );
      await app.parts.catalog.synchronize();
      await pumpEventQueue();
      app.parts.books.activate(clubBook);
      await pumpEventQueue();
      expect(app.shelf.refs.map((r) => r.path), contains(dragon.path));
      expect(app.shelf.bookFiles(app.parts.books.includes).map((f) => f.path), [
        najdorf.path,
        dragon.path,
      ]);
    });
  });
}
