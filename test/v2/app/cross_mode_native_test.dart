import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/features/library/library_state.dart';
import 'package:chess_auto_prep/v2/features/trainer/trainer.dart';
import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart' as storage;
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/storage/file_relocation.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:chess_auto_prep/v2/workspace/gap_walk.dart';
import 'package:chess_auto_prep/v2/workspace/replies.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../storage/store_fixture.dart';
import '../support/native_window_fixture.dart';
import '../workspace/gap_hunt_test.dart' show TwoPositions;

const _course =
    '// Course\n// Color: White\n\n'
    '[Event "Open"]\n[ChapterName "Open"]\n[LineID "open"]\n\n1. e4 e5 2. Nf3 *\n\n'
    '[Event "Queen"]\n[ChapterName "Queen"]\n[LineID "queen"]\n\n1. d4 d5 2. c4 *\n';
const _sibling =
    '// Color: White\n\n[Event "Sicilian"]\n[LineID "sicilian"]\n\n1. e4 c5 2. Nf3 *\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final selectedSibling in [false, true]) {
    test(
      'native composition ${selectedSibling ? 'refuses undo over changed book membership' : 'undoes rename after sibling removal'}',
      () async {
        final disk = await StoreFixture.create();
        addTearDown(disk.dispose);
        final original = ChapterRef.at(
          disk.ref('repertoires/Course/Main.pgn').path,
          section: 'Open',
        );
        final renamed = ChapterRef.at(original.path, section: 'Open games');
        final sibling = ChapterRef.at(
          disk.ref('repertoires/Course/Sicilian.pgn').path,
        );
        await disk.put(original, _course);
        await disk.put(sibling, _sibling);
        await disk.store.books.write(
          BookList(
            active: 'one',
            books: [
              Book(
                id: 'one',
                name: 'Preparation',
                chapters: {
                  const BookChapter('Course/Main.pgn', 'Open'),
                  if (selectedSibling)
                    const BookChapter('Course/Sicilian.pgn', null),
                },
              ),
            ],
          ),
        );
        Completer<void>? published;
        Completer<void>? release;
        final progress = TrainingStore(
          disk.documents,
          support: disk.support,
          publish: (path, bytes) async {
            await replaceFile(path, bytes);
            if (published != null && !published.isCompleted) {
              published.complete();
              await release!.future;
            }
          },
        );
        var app = NativeWindowFixture(
          disk,
          policy: TwoPositions(),
          progress: progress,
        );
        addTearDown(() => app.dispose());
        await app.ready();
        final parts = app.parts;
        await parts.session.open(original);
        parts.session.setComment(
          const NodePath.root(),
          'Prepared before training',
        );
        await parts.saver.flush();
        expect(parts.saver.settled, isTrue);
        final trainer = parts.training.lines;
        trainer.setScope(TrainScope.book);
        await trainer.reload();
        await _ready(trainer);
        expect(trainer.state, isA<TrainerReady>());
        final ready = trainer.state as TrainerReady;
        final line = ready.lines.singleWhere((line) => line.key.id == 'open');
        trainer.drillLines([line]);
        expect(trainer.lesson, isNotNull);
        trainer.lesson!.play('e2e4');
        trainer.leave();
        expect(await parts.env.pendingWrites.settle(), isNull);
        final attempts = File(p.join(disk.documents.path, attemptsFile));
        expect(await attempts.readAsLines(), hasLength(1));
        parts.session.goTo(NodePath.of([0]));
        await _until(
          parts.workspace.gaps,
          () => parts.workspace.gaps.currentWalk != null,
        );
        expect(_missing(parts.workspace.gaps.currentWalk!), ['a7a6']);

        published = Completer<void>();
        release = Completer<void>();
        final rating = ready.progress.finished(line, Rating.good, clean: true);
        await published.future;
        final beforeRename = await File(original.path).readAsString();
        trainer.setScope(TrainScope.repertoire);
        final firstReload = trainer.reload();
        trainer.setScope(TrainScope.book);
        final secondReload = trainer.reload();
        var renamedFinished = false;
        final rename = parts.documents.library
            .renameChapter(original, 'Open games')
            .then((result) {
              renamedFinished = true;
              return result;
            });
        await pumpEventQueue();
        expect(renamedFinished, isFalse);
        expect(trainer.state, isNot(isA<TrainerReady>()));
        expect(await File(original.path).readAsString(), beforeRename);
        release.complete();
        expect(await rating, isA<ProgressWritten>());
        expect(await rename, isA<LibraryDone>());
        await Future.wait([firstReload, secondReload]);
        await parts.catalog.synchronize();
        await trainer.reload();
        await _ready(trainer);
        expect(parts.session.source, renamed);
        expect(parts.books.includes(renamed), isTrue);
        expect(parts.books.includes(original), isFalse);
        expect(
          (trainer.state as TrainerReady).progress.reviews[line.key]!.passes,
          1,
        );
        final history = File(p.join(disk.documents.path, historyFile));
        expect(
          (await history.readAsLines()).where((s) => s.isNotEmpty),
          hasLength(2),
        );

        expect(
          await parts.documents.library.deleteChapter(sibling),
          isA<LibraryDone>(),
        );
        await parts.catalog.synchronize();
        await trainer.reload();
        await _ready(trainer);
        await _until(
          parts.workspace.gaps,
          () => parts.workspace.gaps.currentWalk != null,
        );
        expect(_missing(parts.workspace.gaps.currentWalk!), ['c7c5', 'a7a6']);
        expect(parts.books.includes(sibling), isFalse);
        expect(File(sibling.path).existsSync(), isFalse);
        expect((trainer.state as TrainerReady).lines.map((l) => l.key.id), [
          'open',
        ]);
        final replies = parts.workspace.replies;
        await _until(replies, () => replies.table is RepliesShown);
        final c5 = (replies.table as RepliesShown).rows.singleWhere(
          (r) => r.uci == 'c7c5',
        );
        expect(c5.gap, isTrue);
        expect(c5.elsewhere, isNull);

        final beforeUndo = await File(original.path).readAsString();
        final bookBeforeUndo = await File(
          p.join(disk.support.path, 'books.json'),
        ).readAsString();
        final progressBeforeUndo = await _progressBytes(disk.documents);
        final undone = await parts.session.undo();
        var expected = selectedSibling ? renamed : original;
        if (selectedSibling) {
          expect(undone, isA<UndoRefused>());
          expect(parts.saver.canUndo, isTrue);
          expect(await File(original.path).readAsString(), beforeUndo);
          expect(
            await File(p.join(disk.support.path, 'books.json')).readAsString(),
            bookBeforeUndo,
          );
          expect(await _progressBytes(disk.documents), progressBeforeUndo);
        } else {
          expect(undone, isA<Restored>());
          await parts.catalog.synchronize();
          await trainer.reload();
          await _ready(trainer);
        }
        expect(parts.session.source, expected);
        expect(parts.books.includes(expected), isTrue);
        expect(
          parts.books.includes(selectedSibling ? original : renamed),
          isFalse,
        );
        final savedText = await File(original.path).readAsString();
        expect(savedText, contains('Prepared before training'));
        var savedBook = await File(
          p.join(disk.support.path, 'books.json'),
        ).readAsString();
        var savedProgress = await _progressBytes(disk.documents);
        app.dispose();
        if (!selectedSibling) {
          final destination = ChapterRef.at(
            disk.ref('repertoires/Course/Relocated.pgn').path,
            section: expected.section,
          );
          final interrupted = PgnFileStore(
            documents: disk.documents,
            support: disk.support,
            relocationHook: (step) async {
              if (step == FileRelocationStep.document) {
                throw const FileSystemException(
                  'simulated interruption after PGN relocation',
                );
              }
            },
          );
          final observed = await interrupted.open(original) as storage.Opened;
          expect(
            await interrupted.move(
              original,
              destination,
              expected: observed.revision,
              operationId: 'cross-mode-interrupted',
            ),
            isA<storage.IoFailure>(),
          );
          expect(File(original.path).existsSync(), isFalse);
          expect(await File(destination.path).readAsString(), savedText);
          // The namespace has moved, but the interrupted reference participants
          // still describe its old path. Fresh production composition must fix
          // this before any derived model is usable.
          expect(
            await File(p.join(disk.support.path, 'books.json')).readAsString(),
            savedBook,
          );
          expect(await _progressBytes(disk.documents), savedProgress);
          savedBook = jsonEncode(
            jsonDecode(
              savedBook.replaceAll('Course/Main.pgn', 'Course/Relocated.pgn'),
            ),
          );
          savedProgress = {
            for (final entry in savedProgress.entries)
              entry.key: entry.value == null
                  ? null
                  : utf8.encode(
                      utf8
                          .decode(entry.value!)
                          .replaceAll(original.path, destination.path),
                    ),
          };
          expected = destination;
        }
        app = NativeWindowFixture(disk, policy: TwoPositions());
        await app.ready();
        await app.parts.session.open(expected);
        app.parts.training.lines.setScope(TrainScope.book);
        await app.parts.training.lines.reload();
        await _ready(app.parts.training.lines);
        expect(
          (app.parts.training.lines.state as TrainerReady)
              .progress
              .reviews[(source: expected.path, id: line.key.id)]!
              .passes,
          1,
        );
        await _until(
          app.parts.workspace.gaps,
          () => app.parts.workspace.gaps.currentWalk != null,
        );
        expect(_missing(app.parts.workspace.gaps.currentWalk!), [
          'c7c5',
          'a7a6',
        ]);
        expect(await File(expected.path).readAsString(), savedText);
        expect(
          await File(p.join(disk.support.path, 'books.json')).readAsString(),
          savedBook,
        );
        expect(await _progressBytes(disk.documents), savedProgress);
      },
    );
  }
}

List<String> _missing(GapWalk walk) =>
    walk.gaps.whereType<MissingReply>().map((g) => g.uci).toList();

Future<void> _until(Listenable owner, bool Function() ready) async {
  if (ready()) return;
  final done = Completer<void>();
  void changed() {
    if (ready() && !done.isCompleted) done.complete();
  }

  owner.addListener(changed);
  try {
    await done.future.timeout(const Duration(seconds: 10));
  } finally {
    owner.removeListener(changed);
  }
}

Future<void> _ready(Trainer trainer) => _until(
  trainer,
  () =>
      trainer.state is TrainerReady ||
      trainer.state is TrainerFailed ||
      trainer.state is TrainerUnsaved,
);

Future<Map<String, List<int>?>> _progressBytes(Directory documents) async => {
  for (final name in [reviewsFile, streaksFile, historyFile, attemptsFile])
    name: await File(p.join(documents.path, name)).exists()
        ? await File(p.join(documents.path, name)).readAsBytes()
        : null,
};
