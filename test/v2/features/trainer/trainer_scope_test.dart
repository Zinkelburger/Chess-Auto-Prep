import 'dart:async';

import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/features/trainer/trainer.dart';
import 'package:chess_auto_prep/v2/features/trainer/training_scope.dart';
import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/book_snapshot.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_files.dart';
import '../../support/scripted_progress.dart';
import '../../support/scripted_store.dart';
import '../../support/session_fixture.dart';

const _text = '// Color: White\n\n[Event "Line"]\n\n1. e4 e5 2. Nf3 *';

void main() {
  late SessionFixture session;
  late ScriptedFiles chapters;
  late ScriptedProgress progress;
  late EngineAnalysis analysis;
  late Books books;
  late _HeldBooks bookStore;
  late Trainer trainer;

  setUp(() async {
    session = await openSession(_text);
    chapters = ScriptedFiles(
      listing: Repertoires([
        folder('KID', ['Main', 'Other']),
      ]),
    );
    session.store.documents[ref('KID', 'Other')] = Opened(
      _text,
      scriptedRevision(_text),
    );
    progress = ScriptedProgress();
    analysis = EngineAnalysis(
      session.session,
      () async => const StartFailed('test'),
    );
    bookStore = _HeldBooks();
    books = Books(store: bookStore, root: '/repertoires');
    await books.load();
    trainer = Trainer(
      session: session.session,
      chapters: ScopeReader(files: chapters, documents: session.store),
      files: progress,
      analysis: analysis,
      time: (now: () => DateTime.utc(2026), jitter: () => 0),
      books: books,
    );
  });

  tearDown(() {
    trainer.dispose();
    books.dispose();
    analysis.dispose();
    session.dispose();
  });

  test('an unreadable chapter is left out and the rest are trained', () {
    fakeAsync((clock) {
      session.store.documents[ref('KID', 'Other')] = const Unreadable(
        'disk denied',
      );
      trainer.setScope(TrainScope.repertoire);
      clock.flushMicrotasks();
      final ready = trainer.state as TrainerReady;
      expect(ready.chapters.map((c) => c.ref.name), ['Main']);
    });
  });

  test('a repertoire list that cannot be read trains the open chapter', () {
    fakeAsync((clock) {
      chapters.listing = const RepertoiresUnreadable('folder denied');
      trainer.setScope(TrainScope.repertoire);
      clock.flushMicrotasks();
      final ready = trainer.state as TrainerReady;
      expect(ready.chapters.map((c) => c.ref.name), ['Main']);
    });
  });

  test('a book whose last edit did not save is still trained', () {
    fakeAsync((clock) {
      bookStore.fail = true;
      books.rename(books.active!, 'Retained name');
      trainer.setScope(TrainScope.book);
      clock.flushMicrotasks();
      expect(books.canRetry, isTrue);
      final ready = trainer.state as TrainerReady;
      expect(ready.chapters.map((c) => c.ref.name), ['Main', 'Other']);
      bookStore.fail = false;
      unawaited(trainer.reload());
      clock.flushMicrotasks();
      expect(books.canRetry, isFalse);
      expect(bookStore.value.activeBook!.name, 'Retained name');
      expect(trainer.state, isA<TrainerReady>());
    });
  });

  test('a book edit still being written does not hold training up', () {
    fakeAsync((clock) {
      bookStore.hold = Completer<void>();
      books.rename(books.active!, 'Uncommitted');
      trainer.setScope(TrainScope.book);
      clock.flushMicrotasks();
      expect(trainer.state, isA<TrainerReady>());
      bookStore.hold!.complete();
      clock.flushMicrotasks();
      expect(trainer.state, isA<TrainerReady>());
    });
  });
}

final class _HeldBooks implements BookStore {
  BookList value = const BookList(
    active: 'a',
    books: [
      Book(id: 'a', name: 'A', repertoires: {'KID'}),
    ],
  );
  Completer<void>? hold;
  bool fail = false;

  @override
  Future<BookList> read() async => value;
  @override
  Future<BookSnapshot> snapshot() async => BookSnapshot(value: value);
  @override
  Future<BookSnapshot> write(BookList books) async {
    await hold?.future;
    if (fail) throw StateError('book write failed');
    value = books;
    return BookSnapshot(value: books);
  }
}
