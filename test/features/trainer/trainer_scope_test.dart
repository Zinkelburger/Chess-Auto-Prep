import 'dart:async';

import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/trainer/trainer.dart';
import 'package:chess_auto_prep/features/trainer/trainer_state.dart';
import 'package:chess_auto_prep/features/trainer/training_scope.dart';
import 'package:chess_auto_prep/storage/book_file.dart';
import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:chess_auto_prep/storage/book_snapshot.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/book/books.dart';
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

  test(
    'a line sent to train skips model games, excluded lines and other starts',
    () async {
      const text = '''
// Color: White

[Event "Playable"]
[LineID "play"]

1. e4 e5 2. Nf3 *

[Event "Model"]
[ModelGameResult "1-0"]

1. e4 *

[Event "Excluded"]
[LineID "excluded"]

1. e4 c5 *

[Event "Different start"]
[SetUp "1"]
[FEN "rnbqkbnr/1ppppppp/p7/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 2"]

2. e4 *
''';
      session.externalEdit(text);
      await session.session.reloadFromDisk();
      final key = (source: session.ref.path, id: 'excluded');
      progress.reviews[key] = Review(
        key: key,
        lineName: 'Excluded',
        excluded: true,
      );
      expect(await trainer.trainLineThrough(['e4']), isTrue);
      expect(trainer.lesson!.line.key.id, 'play');
    },
  );

  test('a late prefix request cannot replace the newer lesson', () async {
    const text =
        '$_text\n\n[Event "Queen pawn"]\n[LineID "queen"]\n\n1. d4 d5 *';
    session.externalEdit(text);
    await session.session.reloadFromDisk();
    trainer.setScope(TrainScope.repertoire);
    await trainer.reload();
    chapters.hold = true;
    final older = trainer.trainLineThrough(['e4']);
    await pumpEventQueue();
    final newer = trainer.trainLineThrough(['d4']);
    await pumpEventQueue();
    expect(chapters.pendingCalls, 2);
    chapters.releaseLast();
    expect(await newer, isTrue);
    final lesson = trainer.lesson;
    expect(lesson!.line.key.id, 'queen');
    chapters.releaseNext();
    expect(await older, isFalse);
    expect(trainer.lesson, same(lesson));
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
      books.rename(books.chosen!, 'Retained name');
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
      books.rename(books.chosen!, 'Uncommitted');
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
