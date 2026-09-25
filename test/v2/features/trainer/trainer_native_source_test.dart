import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_sections.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/features/trainer/trainer.dart';
import 'package:chess_auto_prep/v2/features/trainer/training_scope.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart' as store;
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:chess_auto_prep/v2/storage/reference_change.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../storage/store_fixture.dart';

void main() {
  late StoreFixture fixture;
  late DocumentSaver saver;
  late DocumentSession session;
  late Books books;
  late EngineAnalysis analysis;
  late Trainer trainer;
  late ChapterRef ref;
  late TrainingStore progress;
  late PendingWrites pending;
  var failProgress = false;
  Completer<void>? progressPublished;
  Completer<void>? releaseProgress;
  const text =
      '// Course\n// Color: White\n\n'
      '[Event "First"]\n[ChapterName "First"]\n[LineID "first"]\n\n1. e4 e5 *\n\n'
      '[Event "Second"]\n[ChapterName "Second"]\n[LineID "second"]\n\n1. d4 d5 *\n';

  setUp(() async {
    fixture = await StoreFixture.create();
    failProgress = false;
    progressPublished = null;
    releaseProgress = null;
    ref = ChapterRef.at(
      fixture.ref('repertoires/Course/Main.pgn').path,
      section: 'First',
    );
    await fixture.put(ref, text);
    pending = PendingWrites();
    books = Books(
      store: fixture.store.books,
      root: p.join(fixture.documents.path, 'repertoires'),
      pendingWrites: pending,
    );
    await books.load();
    saver = DocumentSaver(
      fixture.store,
      delay: const Duration(days: 1),
      pendingWrites: pending,
      books: books,
      writeGuard: () => trainer,
    );
    session = DocumentSession(fixture.store, saver);
    await session.open(ref);
    analysis = EngineAnalysis(session, () async => const StartFailed('unused'));
    progress = TrainingStore(
      fixture.documents,
      support: fixture.support,
      publish: (path, bytes) async {
        await replaceFile(path, bytes);
        final published = progressPublished;
        if (published != null && !published.isCompleted) {
          published.complete();
          await releaseProgress!.future;
        }
        if (failProgress)
          throw const FileSystemException('progress acknowledgement lost');
      },
    );
    trainer = Trainer(
      session: session,
      chapters: ScopeReader(
        files: ChapterDirectory(
          Directory(p.join(fixture.documents.path, 'repertoires')),
          recovery: fixture.store.recovery,
        ),
        documents: fixture.store,
      ),
      files: progress,
      analysis: analysis,
      books: books,
      pendingWrites: pending,
      time: (now: () => DateTime.utc(2026), jitter: () => 0),
    );
  });
  test('explicit book retry observes new committed membership', () async {
    final first = BookList(
      active: 'a',
      books: [
        Book(
          id: 'a',
          name: 'A',
          chapters: {const BookChapter('Course/Main.pgn', 'First')},
        ),
      ],
    );
    final second = BookList(
      active: 'a',
      books: [
        Book(
          id: 'a',
          name: 'A',
          chapters: {const BookChapter('Course/Main.pgn', 'Second')},
        ),
      ],
    );
    await fixture.store.books.write(first);
    await books.load();
    await fixture.store.books.write(second);
    // This bypasses the Books owner exactly as another window would.
    trainer.setScope(TrainScope.book);
    await pumpEventQueue();
    await trainer.reload();
    final state = trainer.state;
    expect(state, isA<TrainerReady>());
    expect((state as TrainerReady).chapters.map((c) => c.ref.section), [
      'Second',
    ]);
  });

  tearDown(() async {
    trainer.dispose();
    analysis.dispose();
    session.dispose();
    saver.dispose();
    books.dispose();
    await fixture.dispose();
  });

  test(
    'retained line action uses current moves after source replacement',
    () async {
      await trainer.reload();
      final old = (trainer.state as TrainerReady).lines.single;
      await File(ref.path).rename('${ref.path}.original');
      await File(ref.path).writeAsString(text.replaceFirst('e4 e5', 'c4 c5'));
      await session.reloadFromDisk();
      await trainer.reload();
      final ready = trainer.state as TrainerReady;
      final current = ready.lines.single;
      expect(current.key, old.key);
      expect(current.moves.first.san, 'c4');
      expect(old.moves.first.san, 'e4');
      expect(
        await ready.progress.finished(current, Rating.good, clean: true),
        isA<ProgressWritten>(),
      );
      trainer.trainLine(old);
      expect(trainer.lesson!.line, same(current));
      trainer.lesson!.play('c2c4');
      expect(await pending.settle(), isNull);
      final attempts = await File(
        p.join(fixture.documents.path, attemptsFile),
      ).readAsString();
      expect(attempts, contains('"expectedSan":"c4"'));
      expect(attempts, contains('"correct":true'));
    },
  );
  test('retained line action cannot start outside the current scope', () async {
    await trainer.reload();
    final old = (trainer.state as TrainerReady).lines.single;
    await session.open(ChapterRef.at(ref.path, section: 'Second'));
    await trainer.reload();
    trainer.trainLine(old);
    expect(trainer.lesson, isNull);
    expect(await pending.settle(), isNull);
    expect(
      File(p.join(fixture.documents.path, attemptsFile)).existsSync(),
      isFalse,
    );
  });

  test(
    'mismatched save lineage requires reopening the actual source',
    () async {
      await trainer.reload();
      await File(ref.path).rename('${ref.path}.original');
      await File(ref.path).writeAsString(text);
      session.toStart();
      session.playMove('c2c4');
      await saver.flush();
      await _settled(trainer);
      expect(trainer.state, isA<TrainerFailed>());
      await trainer.reload();
      expect(trainer.state, isA<TrainerFailed>());
      await session.reloadFromDisk();
      await _settled(trainer);
      expect(trainer.state, isA<TrainerReady>());
    },
  );

  test(
    'failed accepted progress blocks autosave until exact retry succeeds',
    () async {
      await trainer.reload();
      final ready = trainer.state as TrainerReady;
      failProgress = true;
      expect(
        await ready.progress.finished(
          ready.lines.first,
          Rating.good,
          clean: true,
        ),
        isA<ProgressFailed>(),
      );
      final before = await File(ref.path).readAsString();
      session.toStart();
      session.playMove('c2c4');
      await saver.flush();
      expect(saver.state, isA<SaveFailed>());
      expect(await File(ref.path).readAsString(), before);
      failProgress = false;
      await pending.retry(progress);
      await saver.flush();
      await _settled(trainer);
      expect(saver.settled, isTrue);
      expect(await pending.settle(), isNull);
      expect((trainer.state as TrainerReady).progress, same(ready.progress));
    },
  );

  test(
    'save waits for an accepted rating and releases inputs after adoption',
    () async {
      await trainer.reload();
      final ready = trainer.state as TrainerReady;
      trainer.learn();
      final lesson = trainer.lesson;
      progressPublished = Completer<void>();
      releaseProgress = Completer<void>();
      final rating = ready.progress.finished(
        ready.lines.first,
        Rating.good,
        clean: true,
      );
      await progressPublished!.future;
      session.toStart();
      session.playMove('c2c4');
      final paused = Completer<void>();
      void pauseSeen() {
        if (trainer.documentWriting && !paused.isCompleted) paused.complete();
      }

      trainer.addListener(pauseSeen);
      final saving = saver.flush();
      await paused.future;
      expect(await File(ref.path).readAsString(), text);
      expect(trainer.board.value?.onMove, isNull);
      expect(
        await ready.progress.mark(ready.lines, known: true),
        isA<ProgressFailed>(),
      );
      var heldAtReceipt = false;
      void saved() {
        if (saver.lastReceipt != null) heldAtReceipt = trainer.documentWriting;
      }

      saver.addListener(saved);
      releaseProgress!.complete();
      expect(await rating, isA<ProgressWritten>());
      await saving;
      trainer.removeListener(pauseSeen);
      saver.removeListener(saved);
      expect(heldAtReceipt, isTrue);
      expect(trainer.documentWriting, isFalse);
      expect(trainer.lesson, same(lesson));
      expect((trainer.state as TrainerReady).progress, same(ready.progress));
      expect(
        await File(p.join(fixture.documents.path, historyFile)).readAsLines(),
        hasLength(2),
      );
    },
  );

  test(
    'undo holds training through receipt adoption and restored text',
    () async {
      await trainer.reload();
      session.toStart();
      session.playMove('c2c4');
      await saver.flush();
      final ready = trainer.state as TrainerReady;
      var heldAtReceipt = false;
      var heldAtShown = false;
      final savedReceipt = saver.lastReceipt;
      void saved() {
        if (saver.lastReceipt != savedReceipt)
          heldAtReceipt = trainer.documentWriting;
      }

      void shown() {
        if (saver.lastReceipt != savedReceipt)
          heldAtShown = trainer.documentWriting;
      }

      saver.addListener(saved);
      session.addListener(shown);
      expect(await session.undo(), isA<Restored>());
      saver.removeListener(saved);
      session.removeListener(shown);
      expect(heldAtReceipt, isTrue);
      expect(heldAtShown, isTrue);
      expect(trainer.documentWriting, isFalse);
      expect((trainer.state as TrainerReady).progress, same(ready.progress));
      expect(await File(ref.path).readAsString(), text);
      expect(
        await ready.progress.finished(
          ready.lines.first,
          Rating.good,
          clean: true,
        ),
        isA<ProgressWritten>(),
      );
    },
  );

  test(
    'a disposed former scope still blocks a save until its retry settles',
    () async {
      await trainer.reload();
      final ready = trainer.state as TrainerReady;
      failProgress = true;
      expect(
        await ready.progress.finished(
          ready.lines.first,
          Rating.good,
          clean: true,
        ),
        isA<ProgressFailed>(),
      );
      await trainer.reload();
      expect(trainer.state, isA<TrainerUnsaved>());
      session.toStart();
      session.playMove('c2c4');
      await saver.flush();
      expect(saver.state, isA<SaveFailed>());
      expect(trainer.documentWriting, isFalse);
      expect(await File(ref.path).readAsString(), text);
      failProgress = false;
      await pending.retry(progress);
      await saver.flush();
      await _settled(trainer);
      expect(saver.settled, isTrue);
      expect(await pending.settle(), isNull);
    },
  );

  test(
    'a live compound save carries the native before proof for training',
    () async {
      await trainer.reload();
      final before = session.trainingSourceRevision!;
      expect(
        session.applyToFile(
          (file) => sectionRenamed(file, 'First', 'Renamed'),
          section: 'Renamed',
          references: ReferenceChanges([
            SectionRename(path: ref.path, from: 'First', to: 'Renamed'),
          ]),
        ),
        isNull,
      );
      await saver.flush();
      await _settled(trainer);
      expect(
        saver.lastReceipt!.beforeRevision.nativeIdentity,
        before.nativeIdentity,
      );
      expect(
        session.trainingSourceRevision!.nativeIdentity,
        saver.lastReceipt!.committed.nativeIdentity,
      );
      final ready = trainer.state as TrainerReady;
      expect(
        await ready.progress.finished(
          ready.lines.first,
          Rating.good,
          clean: true,
        ),
        isA<ProgressWritten>(),
      );
    },
  );

  test(
    'a newer sibling read cannot authorize the stale open section',
    () async {
      await fixture.store.rename(
        ref,
        'Other.pgn',
        expected: session.persistedRevision!,
      );
      expect(await fixture.store.create(ref, text), isA<store.Created>());
      trainer.setScope(TrainScope.repertoire);
      await trainer.reload();
      expect(trainer.state, isA<TrainerFailed>());
    },
  );

  test(
    'ordinary save refreshes the native source before the next rating',
    () async {
      await trainer.reload();
      final old = trainer.state as TrainerReady;
      final before = session.persistedRevision!;
      session.toStart();
      session.playMove('c2c4');
      await saver.flush();
      await _settled(trainer);
      expect(
        session.persistedRevision!.nativeIdentity,
        isNot(before.nativeIdentity),
      );
      final ready = trainer.state as TrainerReady;
      expect(ready.progress, same(old.progress));
      expect(
        await ready.progress.finished(
          ready.lines.first,
          Rating.good,
          clean: true,
        ),
        isA<ProgressWritten>(),
      );
      expect(await pending.settle(), isNull);
    },
  );
}

Future<void> _settled(Trainer trainer) async {
  if (trainer.state is! TrainerLoading) return;
  final settled = Completer<void>();
  void changed() {
    if (trainer.state is! TrainerLoading && !settled.isCompleted)
      settled.complete();
  }

  trainer.addListener(changed);
  try {
    await settled.future.timeout(const Duration(seconds: 10));
  } finally {
    trainer.removeListener(changed);
  }
}
