import 'dart:async';

import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/features/trainer/trainer.dart';
import 'package:chess_auto_prep/v2/features/trainer/training_scope.dart';
import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/book_snapshot.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:chess_auto_prep/v2/storage/training_snapshot.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_catalog.dart';
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

  test('an unreadable included chapter refuses the whole repertoire', () {
    fakeAsync((clock) {
      session.store.documents[ref('KID', 'Other')] = const Unreadable(
        'disk denied',
      );
      trainer.setScope(TrainScope.repertoire);
      clock.flushMicrotasks();
      expect(trainer.state, isA<TrainerFailed>());
      expect(progress.reads, 0);
    });
  });

  test('failed membership listing never falls back to the open chapter', () {
    fakeAsync((clock) {
      chapters.listing = const RepertoiresUnreadable('folder denied');
      trainer.setScope(TrainScope.repertoire);
      clock.flushMicrotasks();
      expect(trainer.state, isA<TrainerFailed>());
      expect(progress.reads, 0);
    });
  });

  for (final names in [
    ['Main'],
    ['Main', 'Other', 'Added'],
  ]) {
    test('membership changed during chapter reads refuses $names', () {
      fakeAsync((clock) {
        session.store.hold = true;
        trainer.setScope(TrainScope.repertoire);
        clock.flushMicrotasks();
        expect(session.store.waiting, 1);
        chapters.listing = Repertoires([folder('KID', names)]);
        session.store.hold = false;
        session.store.releaseAll();
        clock.flushMicrotasks();
        expect(trainer.state, isA<TrainerFailed>());
      });
    });
  }

  test(
    'explicit reload reads changed membership beyond the cached catalog',
    () async {
      final catalog = RepertoireCatalog(files: chapters, root: '/repertoires');
      await catalog.refresh();
      trainer.dispose();
      trainer = Trainer(
        session: session.session,
        chapters: ScopeReader(files: chapters, documents: session.store),
        files: progress,
        analysis: analysis,
        time: (now: () => DateTime.utc(2026), jitter: () => 0),
        books: books,
        catalog: catalog,
      );
      chapters.listing = Repertoires([
        folder('KID', ['Main', 'Other', 'Added']),
      ]);
      session.store.documents[ref('KID', 'Added')] = Opened(
        _text,
        scriptedRevision(_text),
      );
      trainer.setScope(TrainScope.repertoire);
      await trainer.reload();
      expect(trainer.state, isA<TrainerReady>());
      expect((trainer.state as TrainerReady).chapters, hasLength(3));
      catalog.dispose();
    },
  );

  test('the final fence follows progress reading and cancellation wins', () {
    fakeAsync((clock) {
      final fence = Completer<RepertoireValidation>();
      chapters.validateWith = (_, observed) {
        expect(progress.reads, 1);
        expect(observed.keys, contains(session.ref.path));
        return fence.future;
      };
      trainer.show();
      clock.flushMicrotasks();
      expect(trainer.state, isA<TrainerLoading>());
      trainer.dispose();
      // The fixture teardown must not dispose this owner twice.
      trainer = Trainer(
        session: session.session,
        chapters: ScopeReader(files: chapters, documents: session.store),
        files: progress,
        analysis: analysis,
        time: (now: () => DateTime.utc(2026), jitter: () => 0),
        books: books,
      );
      fence.complete(const RepertoireCurrent());
      clock.flushMicrotasks();
      expect(trainer.state, isA<TrainerIdle>());
    });
  });

  test(
    'the fence receives the exact progress snapshot decoded by the read',
    () {
      fakeAsync((clock) {
        final snapshot = TrainingReadSet(
          documentsPath: '/profile',
          canonicalDocuments: '/profile',
          files: const {},
        );
        progress.readAs = ProgressLoaded(
          reviews: const {},
          streaks: const {},
          mistakes: const [],
          snapshot: snapshot,
        );
        trainer.show();
        clock.flushMicrotasks();
        expect(trainer.state, isA<TrainerReady>());
        expect(chapters.profileValidations.single.training, same(snapshot));
      });
    },
  );

  test(
    'an accepted write during final validation prevents new progress publication',
    () {
      fakeAsync((clock) {
        final fence = Completer<RepertoireValidation>();
        chapters.validateWith = (_, _) => fence.future;
        trainer.show();
        clock.flushMicrotasks();
        trainer.pendingWrites.accept(
          resource: progress,
          label: 'accepted elsewhere',
          work: () async => const ProgressWritten(),
          problem: (_) => null,
        );
        fence.complete(const RepertoireCurrent());
        clock.flushMicrotasks();
        expect(trainer.state, isA<TrainerUnsaved>());
      });
    },
  );

  test(
    'explicit retry settles retained book edits before reading the scope',
    () {
      fakeAsync((clock) {
        bookStore.fail = true;
        books.rename(books.active!, 'Retained name');
        trainer.setScope(TrainScope.book);
        clock.flushMicrotasks();
        expect(books.canRetry, isTrue);
        expect(trainer.state, isA<TrainerFailed>());
        bookStore.fail = false;
        unawaited(trainer.reload());
        clock.flushMicrotasks();
        expect(books.canRetry, isFalse);
        expect(bookStore.value.activeBook!.name, 'Retained name');
        expect(trainer.state, isA<TrainerReady>());
      });
    },
  );

  test('held optimistic book membership cannot authorize a scope', () {
    fakeAsync((clock) {
      bookStore.hold = Completer<void>();
      books.rename(books.active!, 'Uncommitted');
      trainer.setScope(TrainScope.book);
      clock.flushMicrotasks();
      expect(books.current, isFalse);
      expect(trainer.state, isA<TrainerFailed>());
      bookStore.hold!.complete();
      clock.flushMicrotasks();
      expect(books.current, isTrue);
      unawaited(trainer.reload());
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
