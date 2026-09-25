import 'dart:async';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/features/library/library_state.dart';
import 'package:chess_auto_prep/v2/features/trainer/trainer.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart'
    show Opened, IoFailure;
import '../support/scripted_store.dart' show scriptedRevision;
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';
import '../support/scripted_files.dart' show folder;

const _course =
    '// Color: White\n\n[Event "Course"]\n[ChapterName "First"]\n\n1. e4 e5 *\n\n[Event "Course"]\n[ChapterName "Second"]\n\n1. d4 d5 *\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final rating in [false, true]) {
    test(
      'Library waits for accepted ${rating ? 'rating/history' : 'first attempt'} before moving',
      () async {
        final app = WindowFixture();
        addTearDown(app.dispose);
        await app.library.refresh();
        await app.session.open(kidMain);
        await app.lineTrainer.reload();
        final ready = app.lineTrainer.state as TrainerReady;
        final release = Completer<void>();
        final pending = app.parts.env.pendingWrites;
        final blocker = pending
            .accept<ProgressWrite>(
              resource: app.progress,
              label: 'Earlier training write',
              work: () async {
                await release.future;
                return const ProgressWritten();
              },
              problem: (_) => null,
            )
            .run();
        final accepted = rating
            ? ready.progress.finished(
                ready.lines.first,
                Rating.good,
                clean: true,
              )
            : ready.progress.answered(ready.lines.first, (
                ply: 1,
                fen: Fen.initial,
                played: 'd5',
                expected: 'e5',
                correct: false,
                phase: AttemptPhase.learning,
              ));
        final moving = app.library.renameChapter(kidMain, 'Renamed');
        await pumpEventQueue();
        try {
          expect(
            app.store.documents.containsKey(kidMain),
            isTrue,
            reason:
                'The source cannot move before the accepted old-path write lands.',
          );
          expect(app.lineTrainer.state, isNot(isA<TrainerReady>()));
          expect(
            await ready.progress.mark(ready.lines, known: true),
            isA<ProgressFailed>(),
          );
        } finally {
          release.complete();
        }
        await blocker;
        expect(await accepted, isA<ProgressWritten>());
        expect(await moving, isA<LibraryDone>());
        expect(app.session.source?.path, endsWith('/Renamed.pgn'));
        expect(app.store.documents.containsKey(kidMain), isFalse);
        expect(
          rating ? app.progress.history.length : app.progress.attempts.length,
          1,
        );
        expect(
          await pending.settle(),
          isNull,
          reason: 'The Library command cannot await its own global drain.',
        );
      },
    );
  }

  test(
    'an unresolved training failure refuses relocation and remains retryable',
    () async {
      final app = WindowFixture();
      addTearDown(app.dispose);
      await app.library.refresh();
      await app.session.open(kidMain);
      await app.lineTrainer.reload();
      final ready = app.lineTrainer.state as TrainerReady;
      app.progress.logAs = const ProgressFailed('attempt not acknowledged');
      await ready.progress.answered(ready.lines.first, (
        ply: 1,
        fen: Fen.initial,
        played: 'd5',
        expected: 'e5',
        correct: false,
        phase: AttemptPhase.learning,
      ));
      expect(
        await app.library.renameChapter(kidMain, 'Renamed'),
        isA<LibraryFailure>(),
      );
      expect(app.store.documents.containsKey(kidMain), isTrue);
      expect(app.session.source, kidMain);
      expect(app.lineTrainer.state, isA<TrainerUnsaved>());
      expect(
        await app.parts.env.pendingWrites.settle(),
        contains('attempt not acknowledged'),
      );
      app.progress.logAs = null;
      await app.lineTrainer.retryPending();
      expect(
        await app.library.renameChapter(kidMain, 'Renamed'),
        isA<LibraryDone>(),
      );
      expect(app.progress.attempts, hasLength(1));
    },
  );
  test(
    'training remains retired until the relocated catalog is synchronized',
    () async {
      final app = WindowFixture();
      addTearDown(app.dispose);
      await app.library.refresh();
      await app.session.open(kidMain);
      await app.lineTrainer.reload();
      final old = app.lineTrainer.state as TrainerReady;
      app.chapterFiles.hold = true;
      final moving = app.library.renameChapter(kidMain, 'Renamed');
      await pumpEventQueue();
      expect(
        app.store.documents.containsKey(kidMain),
        isFalse,
        reason: 'The physical move has completed.',
      );
      expect(app.chapterFiles.pendingCalls, greaterThan(0));
      await app.lineTrainer.reload();
      expect(app.lineTrainer.state, isA<TrainerLoading>());
      expect(
        await old.progress.finished(old.lines.first, Rating.good, clean: true),
        isA<ProgressFailed>(),
      );
      app.chapterFiles.listing = Repertoires([
        folder('KID', ['Renamed']),
      ]);
      app.chapterFiles.hold = false;
      app.chapterFiles.releaseAll();
      expect(await moving, isA<LibraryDone>());
      final ready = app.lineTrainer.state as TrainerReady;
      expect(
        ready.lines.every((line) => line.key.source.endsWith('/Renamed.pgn')),
        isTrue,
      );
    },
  );

  test(
    'retained closed rename retry drains training before publication',
    () async {
      final app = WindowFixture();
      addTearDown(app.dispose);
      app.store.documents[benkoMain] = Opened(
        _course,
        scriptedRevision(_course),
      );
      await app.library.refresh();
      await app.session.open(kidMain);
      await app.lineTrainer.reload();
      app.store.saves.add(const IoFailure('uncertain rename'));
      expect(
        await app.library.renameChapter(
          ChapterRef.at(benkoMain.path, section: 'First'),
          'Renamed',
        ),
        isA<LibraryFailure>(),
      );
      final ready = app.lineTrainer.state as TrainerReady;
      app.progress.logAs = const ProgressFailed('held attempt');
      await ready.progress.answered(ready.lines.first, (
        ply: 1,
        fen: Fen.initial,
        played: 'd5',
        expected: 'e5',
        correct: false,
        phase: AttemptPhase.learning,
      ));
      final requested = app.store.requestedSaves.length;
      await app.parts.env.pendingWrites.retry(app.parts.env.store);
      expect(app.store.requestedSaves, hasLength(requested));
      expect((app.store.documents[benkoMain] as Opened).text, _course);
      expect(
        app.parts.env.pendingWrites.unfinished(app.parts.env.store),
        hasLength(1),
      );
      app.progress.logAs = null;
      await app.parts.env.pendingWrites.retry(app.progress);
      await app.parts.env.pendingWrites.retry(app.parts.env.store);
      expect(
        (app.store.documents[benkoMain] as Opened).text,
        contains('[ChapterName "Renamed"]'),
      );
      expect(
        app.parts.env.pendingWrites.unfinished(app.parts.env.store),
        isEmpty,
      );
    },
  );

  for (final kind in [
    'move',
    'delete',
    'folder rename',
    'folder delete',
    'restore',
    'closed section rename',
    'closed section delete',
    'cross-file move',
    'cross-file graft',
  ]) {
    test(
      '$kind refuses an unresolved training attempt before storage changes',
      () async {
        final app = WindowFixture();
        addTearDown(app.dispose);
        app.store.documents[benkoMain] = Opened(
          _course,
          scriptedRevision(_course),
        );
        await app.library.refresh();
        await app.session.open(kidMain);
        await app.lineTrainer.reload();
        final ready = app.lineTrainer.state as TrainerReady;
        app.progress.logAs = const ProgressFailed('held attempt');
        await ready.progress.answered(ready.lines.first, (
          ply: 1,
          fen: Fen.initial,
          played: 'd5',
          expected: 'e5',
          correct: false,
          phase: AttemptPhase.learning,
        ));
        final repertoire = app.library.repertoires.firstWhere(
          (f) => f.name == 'KID',
        );
        final documents = {...app.store.documents};
        final operation = switch (kind) {
          'move' => app.library.moveChapter(
            kidMain,
            app.library.repertoires.firstWhere((f) => f.name == 'benko'),
          ),
          'delete' => app.library.deleteChapter(kidMain),
          'folder rename' => app.library.renameRepertoire(
            repertoire,
            'Renamed',
          ),
          'folder delete' => app.library.deleteRepertoire(repertoire),
          'closed section rename' => app.library.renameChapter(
            ChapterRef.at(benkoMain.path, section: 'First'),
            'Renamed',
          ),
          'closed section delete' => app.library.deleteChapter(
            ChapterRef.at(benkoMain.path, section: 'First'),
          ),
          'cross-file move' => app.library.moveLines(games: {0}, to: benkoMain),
          'cross-file graft' => app.library.moveLines(
            games: {0},
            to: benkoMain,
            asSidelineOf: 0,
          ),
          _ => app.library.restoreChapter(
            DeletedChapter(
              path: '/repertoires/KID/.deleted/Old.pgn',
              folder: '/repertoires/KID',
              name: 'Old',
              deletedAt: DateTime.utc(2026),
            ),
          ),
        };
        expect(await operation, isA<LibraryFailure>());
        expect(app.store.documents, documents);
        expect(app.chapterFiles.removed, isEmpty);
      },
    );
  }
}
