import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/storage/compound_write.dart';
import 'package:chess_auto_prep/storage/document_probe.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/storage/file_lock.dart';
import 'package:chess_auto_prep/storage/file_relocation.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/study_files.dart';
import 'package:chess_auto_prep/storage/training_store.dart';
import 'package:chess_auto_prep/storage/pgn_file_import.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

/// The store a new app session opens, which finishes what an earlier one left.
PgnFileStore restarted(StoreFixture fixture) =>
    PgnFileStore(documents: fixture.documents, support: fixture.support);

/// A store whose moves fail [times] times at [at], as a file held open would
/// make them, and recovery passes that could not run wait [retryDelay].
PgnFileStore failingOnce(
  StoreFixture fixture,
  FileRelocationStep at, {
  int times = 1,
  Duration retryDelay = const Duration(seconds: 30),
}) {
  var left = times;
  return PgnFileStore(
    documents: fixture.documents,
    support: fixture.support,
    recoveryRetry: retryDelay,
    relocationHook: (step) async {
      if (left > 0 && step == at) {
        left--;
        throw const FileSystemException('held open by another program');
      }
    },
  );
}

void main() {
  late StoreFixture fixture;
  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test('first document read recovers a landed move before returning', () async {
    final before = fixture.ref('repertoires/Opening/Old.pgn');
    final after = fixture.ref('repertoires/Opening/New.pgn');
    await fixture.put(before, oneGame('1. d4'));
    final identity = (await probeDocument(before.path) as FileFound).identity;
    final rows = File(
      p.join(fixture.documents.path, 'repertoire_move_progress.csv'),
    );
    await rows.writeAsString(
      'repertoire_id,line_id,move_index,correct_streak,learned\n${before.path},line_1,4,2,true\n',
    );
    await leaveMoveNote(
      fixture.support,
      'landed',
      from: before.path,
      to: after.path,
      identity: identity,
      folder: false,
    );
    await File(before.path).rename(after.path);

    final store = restarted(fixture);
    expect(await store.open(after), isA<Opened>());
    expect(await rows.readAsString(), contains('${after.path},line_1'));
    expect(notedMoves(fixture.support), isEmpty);
    final settled = await rows.readAsBytes();
    expect(await store.open(after), isA<Opened>());
    expect(await rows.readAsBytes(), settled);
  });

  test(
    'a document in a root alias takes the Documents lock only once',
    () async {
      final alias = Link(p.join(fixture.documents.path, 'alias'));
      await alias.create(fixture.documents.path);
      final result = await fixture.store
          .create(fixture.ref('alias/Main.pgn'), oneGame('1. d4'))
          .timeout(const Duration(seconds: 2));
      expect(result, isA<Created>());
      expect(
        await File(p.join(fixture.documents.path, 'Main.pgn')).exists(),
        isTrue,
      );
    },
    skip: Platform.isWindows,
  );

  test('a corrupt recovery note is set aside; read and create work', () async {
    final ref = fixture.ref('repertoires/Opening/Main.pgn');
    await fixture.put(ref, oneGame('1. d4'));
    final note = File(
      p.join(fixture.support.path, 'unfinished-moves', 'bad.json'),
    );
    await note.parent.create(recursive: true);
    await note.writeAsString('not-json');

    final store = restarted(fixture);
    expect(await store.open(ref), isA<Opened>());
    final other = fixture.ref('repertoires/Opening/Other.pgn');
    expect(await store.create(other, oneGame('1. e4')), isA<Created>());
    expect(await note.exists(), isFalse);
    expect(await _setAside(fixture), ['not-json']);
  });

  for (final firstAccess in ['training', 'chapters', 'studies', 'deleted']) {
    test(
      '$firstAccess first access settles all training files exactly once',
      () => _firstAccess(fixture, firstAccess),
    );
  }

  test('a corrupt note blocks no training, listing or import', () async {
    final flat = fixture.ref('repertoires/Flat.pgn');
    await fixture.put(flat, oneGame('1. d4'));
    final note = File(
      p.join(fixture.support.path, 'unfinished-moves', 'bad.json'),
    );
    await note.parent.create(recursive: true);
    await note.writeAsString('not-json');
    final training = TrainingStore(fixture.documents, support: fixture.support);
    expect(await training.read({flat.path}), isA<ProgressLoaded>());
    expect(await training.write(), isA<ProgressWritten>());
    final store = restarted(fixture);
    final chapters = ChapterDirectory(
      Directory(p.join(fixture.documents.path, 'repertoires')),
      recovery: store.recovery,
      documents: store,
    );
    expect(await chapters.list(), isA<Repertoires>());
    expect(await chapters.deleted(), isA<DeletedChapters>());
    expect(
      await StudyDirectory(
        Directory(p.join(fixture.documents.path, 'studies')),
        recovery: store.recovery,
      ).list(),
      isA<StudiesListed>(),
    );
    final external = File(p.join(fixture.root.path, 'Imported.pgn'));
    await external.writeAsString(oneGame('1. e4'));
    final imported = await NativePgnFileImport(
      documents: fixture.documents.path,
      into: p.join(fixture.documents.path, 'pgn_collections'),
      recovery: store.recovery,
    ).insideDocuments(external.path);
    expect(imported, isNot(isA<ImportFailed>()));
    expect(await _setAside(fixture), ['not-json']);
  });

  group('a move that failed after the rename', () {
    late DocumentRef a;
    late DocumentRef b;
    late PgnFileStore store;

    setUp(() async {
      a = fixture.ref('repertoires/Course/A.pgn');
      b = fixture.ref('repertoires/Course/B.pgn');
      final revision = await fixture.put(a, oneGame('1. d4'));
      await fixture.train(a);
      store = failingOnce(fixture, FileRelocationStep.reviews);
      expect(await store.move(a, b, expected: revision), isA<IoFailure>());
      expect(await File(b.path).exists(), isTrue);
    });

    test('is finished on the next access in the same process', () async {
      expect(await store.open(b), isA<Opened>());
      expect(fixture.unfinishedMoves(), isEmpty);
      await fixture.expectTrained(b);
    });

    test('is not set aside by an edit made before the restart', () async {
      final opened = await store.open(b) as Opened;
      expect(
        await store.save(
          b,
          oneGame('1. d4 d5'),
          expected: opened.revision,
          scope: GamesEdited(GamesWritten(rewritten: const {0})),
        ),
        isA<Saved>(),
      );
      expect(await restarted(fixture).open(b), isA<Opened>());
      expect(fixture.quarantined(), isEmpty);
      await fixture.expectTrained(b);
    });
  }, skip: !Platform.isLinux);

  group('a move whose old folder was removed after the rename', () {
    late DocumentRef a;
    late DocumentRef b;
    late DocumentRef c;
    late Revision revision;

    setUp(() async {
      a = fixture.ref('repertoires/A/x.pgn');
      b = fixture.ref('repertoires/B/x.pgn');
      c = fixture.ref('repertoires/C/x.pgn');
      revision = await fixture.put(a, oneGame('1. d4'));
      await fixture.train(a);
    });

    test('finishes on the next access after a restart', () async {
      final store = failingOnce(fixture, FileRelocationStep.reviews);
      expect(await store.move(a, b, expected: revision), isA<IoFailure>());
      expect(await File(b.path).exists(), isTrue);
      Directory(p.dirname(a.path)).deleteSync();

      final restart = restarted(fixture);
      final opened = await restart.open(b) as Opened;
      expect(fixture.unfinishedMoves(), isEmpty);
      expect(fixture.quarantined(), isEmpty);
      await fixture.expectTrained(b);
      expect(await restart.move(b, c, expected: opened.revision), isA<Moved>());
    });

    test('finishes once saves were let pass', () async {
      var ahead = Duration.zero;
      var held = true;
      final store = PgnFileStore(
        documents: fixture.documents,
        support: fixture.support,
        recoveryClock: () => DateTime.now().add(ahead),
        relocationHook: (step) async {
          if (held && step == FileRelocationStep.reviews) {
            throw const FileSystemException('held open by another program');
          }
        },
      );
      expect(await store.move(a, b, expected: revision), isA<IoFailure>());
      final opened = await store.open(b) as Opened;
      ahead = const Duration(minutes: 6);
      expect(
        await store.save(
          b,
          oneGame('1. d4 d5'),
          expected: opened.revision,
          scope: GamesEdited(GamesWritten(rewritten: const {0})),
        ),
        isA<Saved>(),
      );
      expect(
        fixture.unfinishedMoves().map((entry) => p.extension(entry.path)),
        contains('.following'),
      );
      Directory(p.dirname(a.path)).deleteSync();

      held = false;
      final saved = await store.open(b) as Opened;
      expect(saved.text, oneGame('1. d4 d5'));
      expect(fixture.unfinishedMoves(), isEmpty);
      expect(fixture.quarantined(), isEmpty);
      await fixture.expectTrained(b);
      expect(await store.move(b, c, expected: saved.revision), isA<Moved>());
    });
  }, skip: !Platform.isLinux);

  test(
    'a move still held at the first retry is retried before the next edit',
    () async {
      final a = fixture.ref('repertoires/Course/A.pgn');
      final b = fixture.ref('repertoires/Course/B.pgn');
      final revision = await fixture.put(a, oneGame('1. d4'));
      await fixture.train(a);
      final store = failingOnce(
        fixture,
        FileRelocationStep.reviews,
        times: 2,
        retryDelay: const Duration(hours: 1),
      );
      expect(await store.move(a, b, expected: revision), isA<IoFailure>());
      final opened = await store.open(b) as Opened;
      expect(fixture.unfinishedMoves(), isNotEmpty);
      expect(
        await store.save(
          b,
          oneGame('1. d4 d5'),
          expected: opened.revision,
          scope: GamesEdited(GamesWritten(rewritten: const {0})),
        ),
        isA<Saved>(),
      );
      expect(fixture.unfinishedMoves(), isEmpty);
      expect(await restarted(fixture).open(b), isA<Opened>());
      expect(fixture.quarantined(), isEmpty);
      await fixture.expectTrained(b);
    },
    skip: !Platform.isLinux,
  );

  test(
    'a pass that could not run waits its delay before the next',
    () async {
      const delay = Duration(seconds: 3);
      final a = fixture.ref('repertoires/Course/A.pgn');
      final b = fixture.ref('repertoires/Course/B.pgn');
      final revision = await fixture.put(a, oneGame('1. d4'));
      await fixture.train(a);
      final store = failingOnce(
        fixture,
        FileRelocationStep.reviews,
        retryDelay: delay,
      );
      final edits = Directory(p.join(fixture.support.path, 'compound-writes'));
      await edits.create(recursive: true);
      await Process.run('chmod', ['000', edits.path]);
      try {
        expect(await store.open(a), isA<Opened>());
      } finally {
        await Process.run('chmod', ['u+rwX', edits.path]);
      }
      expect(await store.move(a, b, expected: revision), isA<IoFailure>());
      expect(await store.open(b), isA<Opened>());
      expect(fixture.unfinishedMoves(), isNotEmpty);
      await Future<void>.delayed(delay);
      expect(await store.open(b), isA<Opened>());
      expect(fixture.unfinishedMoves(), isEmpty);
      await fixture.expectTrained(b);
    },
    skip: !Platform.isLinux || Platform.environment['USER'] == 'root'
        ? 'requires Linux permissions without root'
        : false,
  );

  group('an operation recorded and stopped for now answers Unfinished', () {
    test(
      'a move, while one the gate refuses meanwhile fails plainly',
      () async {
        final a = fixture.ref('repertoires/Course/A.pgn');
        final b = fixture.ref('repertoires/Course/B.pgn');
        final c = fixture.ref('repertoires/Course/C.pgn');
        final revision = await fixture.put(a, oneGame('1. d4'));
        await fixture.train(a);
        final store = failingOnce(
          fixture,
          FileRelocationStep.reviews,
          times: 2,
          retryDelay: const Duration(hours: 1),
        );
        expect(await store.move(a, b, expected: revision), isA<Unfinished>());
        final refused = await store.move(
          b,
          c,
          expected: await fixture.revisionOf(b),
        );
        expect(refused, isA<IoFailure>());
        expect(refused, isNot(isA<Unfinished>()));
        expect(await store.open(b), isA<Opened>());
        expect(fixture.unfinishedMoves(), isEmpty);
        await fixture.expectTrained(b);
      },
    );

    test('a folder move', () async {
      final from = p.join(fixture.documents.path, 'repertoires', 'Old');
      final to = p.join(fixture.documents.path, 'repertoires', 'New');
      await fixture.put(
        fixture.ref('repertoires/Old/Main.pgn'),
        oneGame('1. e4'),
      );
      final store = failingOnce(fixture, FileRelocationStep.reviews);
      expect(await store.moveFolder(from, to), isA<FolderMoveUnfinished>());
      expect(
        await store.open(fixture.ref('repertoires/New/Main.pgn')),
        isA<Opened>(),
      );
      expect(fixture.unfinishedMoves(), isEmpty);
    });

    test('a pair', () async {
      Future<DocumentEdit> edit(String name) async {
        final ref = fixture.ref('repertoires/$name/Main.pgn');
        await fixture.put(ref, oneGame('1. e4'));
        return DocumentEdit(
          ref: ref,
          text: oneGame('1. d4'),
          expected: await fixture.revisionOf(ref),
          scope: GamesEdited(GamesWritten(rewritten: const {0})),
        );
      }

      final source = await edit('Source');
      final target = await edit('Target');
      var held = true;
      final store = PgnFileStore(
        documents: fixture.documents,
        support: fixture.support,
        compoundHook: (step) async {
          if (held && step == CompoundWriteStep.document) {
            throw const FileSystemException('held open by another program');
          }
        },
      );
      expect(
        await store.savePair(source, target, operationId: 'pair'),
        isA<Unfinished>(),
      );
      held = false;
      expect((await store.open(target.ref) as Opened).text, oneGame('1. d4'));
      expect((await store.open(source.ref) as Opened).text, oneGame('1. d4'));
    });
  }, skip: !Platform.isLinux);

  test(
    'a folder move that failed after the rename finishes on the next access',
    () async {
      final from = p.join(fixture.documents.path, 'repertoires', 'Old');
      final to = p.join(fixture.documents.path, 'repertoires', 'New');
      final chapter = fixture.ref('repertoires/Old/Main.pgn');
      await fixture.put(chapter, oneGame('1. e4'));
      await fixture.train(chapter);
      final store = failingOnce(fixture, FileRelocationStep.reviews);
      expect(await store.moveFolder(from, to), isA<FolderMoveFailed>());
      expect(await Directory(to).exists(), isTrue);
      final moved = fixture.ref('repertoires/New/Main.pgn');
      expect(await store.open(moved), isA<Opened>());
      expect(fixture.unfinishedMoves(), isEmpty);
      await fixture.expectTrained(moved);
    },
    skip: !Platform.isLinux,
  );

  test(
    'a pair left unfinished finishes before training writes over it',
    () async {
      Future<DocumentEdit> edit(
        String name, {
        Map<String, String>? moved,
      }) async {
        final ref = fixture.ref('repertoires/$name/Main.pgn');
        await fixture.put(ref, oneGame('1. e4'));
        return DocumentEdit(
          ref: ref,
          text: oneGame('1. d4'),
          expected: await fixture.revisionOf(ref),
          scope: GamesEdited(GamesWritten(rewritten: const {0})),
          movedLines: moved ?? const {},
        );
      }

      final source = await edit('Source', moved: const {'old': 'new'});
      final target = await edit('Target');
      final streaks = File(p.join(fixture.documents.path, streaksFile));
      await streaks.writeAsString(
        '$streaksHeader\n${source.ref.path},old,0,3,true\n',
      );
      var armed = true;
      final store = PgnFileStore(
        documents: fixture.documents,
        support: fixture.support,
        compoundHook: (step) async {
          if (armed && step == CompoundWriteStep.secondaryDocument) {
            armed = false;
            throw const FileSystemException('held open by another program');
          }
        },
      );
      // Built as the app builds it, and already past its first access.
      final training = TrainingStore(
        fixture.documents,
        support: fixture.support,
        recovery: store.recovery,
      );
      expect(await training.read({target.ref.path}), isA<ProgressLoaded>());
      expect(
        await store.savePair(source, target, operationId: 'pair'),
        isA<IoFailure>(),
      );
      // The trainer opens the target and answers a move of it.
      final loaded = await training.read({target.ref.path}) as ProgressLoaded;
      final answered = await training.logAttempt(
        Attempt(
          key: (source: target.ref.path, id: 'new'),
          ply: 0,
          fen: Fen.initial,
          played: 'd4',
          expected: 'e4',
          correct: false,
          phase: AttemptPhase.drilling,
          at: DateTime.utc(2026, 9, 29),
        ),
        operation: ProgressOperation(sources: loaded.sources),
      );
      expect(answered, isA<ProgressWritten>());
      expect(await restarted(fixture).open(target.ref), isA<Opened>());
      expect(fixture.quarantined(), isEmpty);
      expect(
        await streaks.readAsString(),
        '$streaksHeader\n${target.ref.path},new,0,3,true\n',
      );
      expect(
        await File(p.join(fixture.documents.path, attemptsFile)).readAsString(),
        contains(target.ref.path),
      );
      expect(await File(target.ref.path).readAsString(), oneGame('1. d4'));
    },
  );

  group('a pair a stopped process left half done', () {
    const moved = {'old': 'new'};
    late DocumentEdit source;
    late DocumentEdit target;
    late DocumentRef other;
    late File streaks;

    setUp(() async {
      Future<DocumentEdit> chapter(
        String name, {
        Map<String, String>? lines,
      }) async {
        final ref = fixture.ref('repertoires/$name/Main.pgn');
        await fixture.put(ref, oneGame('1. e4'));
        return DocumentEdit(
          ref: ref,
          text: oneGame('1. d4'),
          expected: await fixture.revisionOf(ref),
          scope: GamesEdited(GamesWritten(rewritten: const {0})),
          movedLines: lines ?? const {},
        );
      }

      source = await chapter('Source', lines: moved);
      target = await chapter('Target');
      other = fixture.ref('repertoires/Other/Main.pgn');
      await fixture.put(other, oneGame('1. c4'));
      streaks = File(p.join(fixture.documents.path, streaksFile));
      await streaks.writeAsString(
        '$streaksHeader\n${source.ref.path},old,0,3,true\n'
        '${other.path},line,0,2,true\n',
      );
      // The process stops once the source is written.
      final stopped = PgnFileStore(
        documents: fixture.documents,
        support: fixture.support,
        compoundHook: (step) async {
          if (step == CompoundWriteStep.document) throw StateError('stopped');
        },
      );
      expect(
        await stopped.savePair(source, target, operationId: 'pair'),
        isA<IoFailure>(),
      );
      expect(await File(source.ref.path).readAsString(), oneGame('1. d4'));
      expect(await File(target.ref.path).readAsString(), oneGame('1. e4'));
    });

    List<FileSystemEntity> unfinishedEdits() {
      final folder = Directory(p.join(fixture.support.path, 'compound-writes'));
      return folder.existsSync() ? folder.listSync() : const [];
    }

    Future<SaveResult> edit(PgnFileStore store, Revision expected) =>
        store.save(
          target.ref,
          oneGame('1. c4'),
          expected: expected,
          scope: GamesEdited(GamesWritten(rewritten: const {0})),
        );

    test('refuses writes to its PGNs while one is held open', () async {
      var held = true;
      final store = PgnFileStore(
        documents: fixture.documents,
        support: fixture.support,
        compoundHook: (step) async {
          if (held && step == CompoundWriteStep.document) {
            throw const FileSystemException('held open by another program');
          }
        },
      );
      final training = TrainingStore(
        fixture.documents,
        support: fixture.support,
        recovery: store.recovery,
      );
      final opened = await store.open(target.ref) as Opened;
      expect(opened.text, oneGame('1. e4'));
      expect(await edit(store, opened.revision), isA<IoFailure>());
      expect(
        await store.move(
          target.ref,
          fixture.ref('repertoires/Target/Renamed.pgn'),
          expected: opened.revision,
        ),
        isA<IoFailure>(),
      );
      final loaded = await training.read({target.ref.path}) as ProgressLoaded;
      expect(
        await training.logAttempt(
          Attempt(
            key: (source: target.ref.path, id: 'new'),
            ply: 0,
            fen: Fen.initial,
            played: 'd4',
            expected: 'e4',
            correct: false,
            phase: AttemptPhase.drilling,
            at: DateTime.utc(2026, 9, 29),
          ),
          operation: ProgressOperation(sources: loaded.sources),
        ),
        // The training rows follow the PGNs as they are when it finishes.
        isA<ProgressWritten>(),
      );
      expect(await File(target.ref.path).readAsString(), oneGame('1. e4'));
      expect(unfinishedEdits(), isNotEmpty);

      held = false;
      final finished = await store.open(target.ref) as Opened;
      expect(finished.text, oneGame('1. d4'));
      expect(unfinishedEdits(), isEmpty);
      expect(fixture.quarantined(), isEmpty);
      expect(
        await streaks.readAsString(),
        contains('\n${target.ref.path},new,0,3,true\n'),
      );
      expect(await edit(store, finished.revision), isA<Saved>());
      expect(await restarted(fixture).open(target.ref), isA<Opened>());
      expect(fixture.quarantined(), isEmpty);
    });

    test('moves another chapter while one is held open', () async {
      var held = true;
      final store = PgnFileStore(
        documents: fixture.documents,
        support: fixture.support,
        compoundHook: (step) async {
          if (held && step == CompoundWriteStep.document) {
            throw const FileSystemException('held open by another program');
          }
        },
      );
      final renamed = fixture.ref('repertoires/Other/Renamed.pgn');
      final opened = await store.open(other) as Opened;
      // The pair guards only its PGNs: the streaks it still has to move are
      // moved again once it finishes, as the move left them.
      expect(
        await store.move(other, renamed, expected: opened.revision),
        isA<Moved>(),
      );
      expect(File(other.path).existsSync(), isFalse);
      expect(unfinishedEdits(), isNotEmpty);

      held = false;
      expect(((await store.open(target.ref)) as Opened).text, oneGame('1. d4'));
      expect(unfinishedEdits(), isEmpty);
      expect(fixture.quarantined(), isEmpty);
      final after = await streaks.readAsString();
      expect(after, contains('${target.ref.path},new,0,3,true'));
      expect(after, contains('${renamed.path},line,0,2,true'));
      expect(await restarted(fixture).open(renamed), isA<Opened>());
      expect(fixture.quarantined(), isEmpty);
    });

    group('owed for too long', () {
      var ahead = Duration.zero;
      var held = true;
      PgnFileStore holding(CompoundWriteStep at) => PgnFileStore(
        documents: fixture.documents,
        support: fixture.support,
        recoveryClock: () => DateTime.now().add(ahead),
        compoundHook: (step) async {
          if (held && step == at) {
            throw const FileSystemException('held open by another program');
          }
        },
      );
      setUp(() {
        ahead = Duration.zero;
        held = true;
      });

      test('is undone whole when a save meets it before it landed', () async {
        final store = holding(CompoundWriteStep.document);
        final opened = await store.open(target.ref) as Opened;
        expect(await edit(store, opened.revision), isA<IoFailure>());
        ahead = const Duration(minutes: 6);
        expect(await edit(store, opened.revision), isA<Saved>());
        // The source has its line back; the target has the save.
        expect(await File(source.ref.path).readAsString(), oneGame('1. e4'));
        expect(await File(target.ref.path).readAsString(), oneGame('1. c4'));
        expect(unfinishedEdits(), isEmpty);
        expect(fixture.quarantined(), hasLength(1));
        expect(
          await streaks.readAsString(),
          contains('\n${source.ref.path},old,0,3,true\n'),
        );
      });

      test('lets saves pass once its PGNs landed, then follows', () async {
        final store = holding(CompoundWriteStep.training);
        final opened = await store.open(target.ref) as Opened;
        expect(opened.text, oneGame('1. d4'));
        expect(await edit(store, opened.revision), isA<IoFailure>());
        ahead = const Duration(minutes: 6);
        expect(await edit(store, opened.revision), isA<Saved>());
        expect(
          unfinishedEdits().map((entry) => p.extension(entry.path)),
          unorderedEquals(['.json', '.following']),
        );
        held = false;
        final saved = await store.open(target.ref) as Opened;
        expect(saved.text, oneGame('1. c4'));
        expect(unfinishedEdits(), isEmpty);
        expect(fixture.quarantined(), isEmpty);
        expect(await File(target.ref.path).readAsString(), oneGame('1. c4'));
        expect(
          await streaks.readAsString(),
          contains('\n${target.ref.path},new,0,3,true\n'),
        );
      });

      test('follows while the folder of its PGN cannot be flushed', () async {
        final store = holding(CompoundWriteStep.training);
        final opened = await store.open(target.ref) as Opened;
        expect(await edit(store, opened.revision), isA<IoFailure>());
        ahead = const Duration(minutes: 6);
        expect(await edit(store, opened.revision), isA<Saved>());
        held = false;
        // The flush fails for a real reason; the PGNs landed long ago and
        // the user has saved over one since, so it is not tried again.
        final saved = await withFolderFlushFailing(
          p.dirname(target.ref.path),
          5,
          () => store.open(target.ref),
        );
        expect((saved as Opened).text, oneGame('1. c4'));
        expect(unfinishedEdits(), isEmpty);
        expect(fixture.quarantined(), isEmpty);
        expect(
          await streaks.readAsString(),
          contains('\n${target.ref.path},new,0,3,true\n'),
        );
      }, skip: !Platform.isLinux);
    });

    test('finishes before a save that waited on its locks', () async {
      final store = restarted(fixture);
      final release = Completer<void>();
      final holding = withDirectoryLock(fixture.support, () => release.future);
      final opening = store.open(target.ref);
      final saving = edit(store, target.expected);
      release.complete();
      await holding;
      expect(((await opening) as Opened).text, oneGame('1. d4'));
      expect(await saving, isA<Conflict>());
      expect(await File(target.ref.path).readAsString(), oneGame('1. d4'));
      expect(unfinishedEdits(), isEmpty);
      expect(fixture.quarantined(), isEmpty);
      expect(
        await edit(store, await fixture.revisionOf(target.ref)),
        isA<Saved>(),
      );
    });
  });
  test('a pair owed too long with one PGN unchanged lets saves pass', () async {
    final source = fixture.ref('repertoires/Source/Main.pgn');
    final target = fixture.ref('repertoires/Target/Main.pgn');
    await fixture.put(source, oneGame('1. e4'));
    await fixture.put(target, oneGame('1. e4'));
    final streaks = File(p.join(fixture.documents.path, streaksFile));
    await streaks.writeAsString(
      '$streaksHeader\n${source.path},old,0,3,true\n',
    );
    var ahead = Duration.zero;
    var held = true;
    final store = PgnFileStore(
      documents: fixture.documents,
      support: fixture.support,
      recoveryClock: () => DateTime.now().add(ahead),
      compoundHook: (step) async {
        if (held && step == CompoundWriteStep.training) {
          throw const FileSystemException('held open by another program');
        }
      },
    );
    final scope = GamesEdited(GamesWritten(rewritten: const {0}));
    final unchanged = await fixture.revisionOf(target);
    // The target is left as it is: the source alone lands.
    expect(
      await store.savePair(
        DocumentEdit(
          ref: source,
          text: oneGame('1. d4'),
          expected: await fixture.revisionOf(source),
          scope: scope,
          movedLines: const {'old': 'new'},
        ),
        DocumentEdit(
          ref: target,
          text: oneGame('1. e4'),
          expected: unchanged,
          scope: scope,
        ),
        operationId: 'unchanged',
      ),
      isA<IoFailure>(),
    );
    Future<SaveResult> edit() =>
        store.save(target, oneGame('1. c4'), expected: unchanged, scope: scope);
    expect(await edit(), isA<IoFailure>());
    ahead = const Duration(minutes: 6);
    expect(await edit(), isA<Saved>());
    // The landed source is kept, not put back, and the record follows.
    expect(await File(source.path).readAsString(), oneGame('1. d4'));
    final records = Directory(p.join(fixture.support.path, 'compound-writes'));
    expect(
      records.listSync().map((entry) => p.extension(entry.path)),
      unorderedEquals(['.json', '.following']),
    );
    held = false;
    expect(((await store.open(target)) as Opened).text, oneGame('1. c4'));
    expect(records.listSync(), isEmpty);
    expect(fixture.quarantined(), isEmpty);
    expect(
      await streaks.readAsString(),
      contains('\n${target.path},new,0,3,true\n'),
    );
  });
}

Future<List<String>> _setAside(StoreFixture fixture) async => [
  await for (final entry in Directory(
    p.join(fixture.support.path, 'recovery-quarantine'),
  ).list(recursive: true))
    if (entry is File) await entry.readAsString(),
];

Future<void> _firstAccess(StoreFixture fixture, String firstAccess) async {
  final before = fixture.ref('repertoires/Opening/Old.pgn');
  final after = fixture.ref('repertoires/Opening/New.pgn');
  await fixture.put(before, oneGame('1. d4'));
  final identity = (await probeDocument(before.path) as FileFound).identity;
  final files = {
    'repertoire_reviews.csv':
        'repertoire_id,line_id,line_name,ease,interval_days,due_at,last_rating,last_reviewed_at,passes,fails,excluded\n${before.path},line_1,Main,2.5,1,,good,,1,0,false\n',
    'repertoire_move_progress.csv':
        'repertoire_id,line_id,move_index,correct_streak,learned\n${before.path},line_1,4,2,true\n',
    'repertoire_review_history.csv':
        'repertoire_id,line_id,reviewed_at,rating,mistake,kind\n${before.path},line_1,2026-09-24T00:00:00Z,good,false,trainer\n',
    'repertoire_move_attempts.jsonl':
        '{"repertoireId":"${before.path}","lineId":"line_1"}\n',
  };
  for (final entry in files.entries) {
    await File(
      p.join(fixture.documents.path, entry.key),
    ).writeAsString(entry.value);
  }
  await leaveMoveNote(
    fixture.support,
    'landed',
    from: before.path,
    to: after.path,
    identity: identity,
    folder: false,
  );
  await File(before.path).rename(after.path);
  final store = restarted(fixture);
  final chapters = ChapterDirectory(
    Directory(p.join(fixture.documents.path, 'repertoires')),
    recovery: store.recovery,
  );
  switch (firstAccess) {
    case 'training':
      final loaded = await TrainingStore(
        fixture.documents,
        support: fixture.support,
      ).read({after.path});
      expect(loaded, isA<ProgressLoaded>());
      expect((loaded as ProgressLoaded).reviews.keys.single.source, after.path);
    case 'chapters':
      expect(await chapters.list(), isA<Repertoires>());
    case 'studies':
      expect(
        await StudyDirectory(
          Directory(p.join(fixture.documents.path, 'studies')),
          recovery: store.recovery,
        ).list(),
        isA<StudiesListed>(),
      );
    case 'deleted':
      expect(await chapters.deleted(), isA<DeletedChapters>());
  }
  expect(notedMoves(fixture.support), isEmpty);
  for (final entry in files.entries) {
    final file = File(p.join(fixture.documents.path, entry.key));
    expect(
      await file.readAsString(),
      entry.value.replaceAll(before.path, after.path),
    );
  }
  expect(await fixture.store.open(after), isA<Opened>());
  for (final entry in files.entries) {
    expect(
      await File(p.join(fixture.documents.path, entry.key)).readAsString(),
      entry.value.replaceAll(before.path, after.path),
    );
  }
}
