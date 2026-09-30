import 'dart:async';
import 'dart:io';
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/study.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart' show lineTree;
import 'package:chess_auto_prep/workspace/document_saver.dart';
import 'package:chess_auto_prep/workspace/session_results.dart';
import 'package:chess_auto_prep/workspace/study_choice.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:chess_auto_prep/storage/pgn_export.dart';
import 'package:chess_auto_prep/storage/pgn_file_import.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:chess_auto_prep/chess/players/player.dart';
import '../../support/viewer_fixture.dart';
import '../../support/scripted_store.dart';
import 'package:chess_auto_prep/features/study/studies.dart';
import 'package:chess_auto_prep/net/lichess_studies.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/study_files.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/storage/file_relocation.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/workspace/document_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../storage/store_fixture.dart';
import '../../support/study_fixture.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'export holds the clicked snapshot across navigation during its picker',
    () async {
      final folder = await Directory.systemTemp.createTemp('study-export-');
      addTearDown(() => folder.delete(recursive: true));
      final choice = Completer<String?>();
      final study = await openStudy(
        twoChapterStudy,
        exporter: PgnExport(pickDirectory: () => choice.future),
      );
      addTearDown(study.dispose);
      final work = study.studies.exportPgn('Snapshot');
      await pumpEventQueue();
      final other = studyRef('Other');
      study.store.documents[other] = Opened(
        '[Event "Other"]\n\n1. c4 *\n',
        scriptedRevision('[Event "Other"]\n\n1. c4 *\n'),
      );
      await study.session.open(other, game: 0);
      choice.complete(folder.path);
      expect(await work, isA<StudyDone>());
      expect(
        await File(p.join(folder.path, 'Snapshot.pgn')).readAsString(),
        twoChapterStudy,
      );
      expect(study.session.source, other);
    },
  );

  test(
    'PGN import preserves original bytes and chooses a free study name',
    () async {
      final picker = ScriptedPicker('/Downloads/Imported.pgn');
      final importer = ScriptedImport()
        ..picked['/Downloads/Imported.pgn'] = const PickedText(twoChapterStudy);
      final study = await openStudy(
        twoChapterStudy,
        picker: picker,
        importer: importer,
      );
      addTearDown(study.dispose);
      study.store.documents[studyRef('Imported')] = Opened(
        'original',
        scriptedRevision('original'),
      );
      final imported = await study.studies.importPgn() as StudyDone;
      expect(imported.opened, studyRef('Imported 2'));
      expect(
        (study.store.documents[imported.opened] as Opened).text,
        twoChapterStudy,
      );
      expect(
        (study.store.documents[studyRef('Imported')] as Opened).text,
        'original',
      );
      expect(study.session.source, study.ref);
      expect(importer.asked, isEmpty, reason: 'no copy is made to open');
      expect(importer.reads, ['/Downloads/Imported.pgn']);
    },
  );
  test(
    'PGN import refuses a file that is not UTF-8, and files nothing',
    () async {
      final importer = ScriptedImport()
        ..picked['/Downloads/Latin.pgn'] = const PickedText(
          '[Event "Caf\u00e9"]\n\n1. e4 *\n',
          foreignEncoding: 'this file is not UTF-8',
        );
      final study = await openStudy(
        twoChapterStudy,
        picker: ScriptedPicker('/Downloads/Latin.pgn'),
        importer: importer,
      );
      addTearDown(study.dispose);
      final result = await study.studies.importPgn() as StudyProblem;
      expect(result.sentence, 'this file is not UTF-8');
      expect(study.store.documents.keys, [study.ref]);
      expect(importer.asked, isEmpty);
    },
  );
  test(
    'a save with uncertain acknowledgment retries the same snapshot',
    () async {
      final pending = PendingWrites();
      final study = await openStudy(twoChapterStudy, pending: pending);
      addTearDown(study.dispose);
      study.store.creates.add(const IoFailure('lost acknowledgment'));
      expect(await study.studies.create('New'), isA<StudyProblem>());
      expect(study.studies.canRetrySave, isTrue);
      expect(await pending.settle(), contains('lost acknowledgment'));
      final landed = newStudyText(study: 'New', chapter: 'Chapter 1');
      study.store.documents[studyRef('New')] = Opened(
        landed,
        scriptedRevision(landed),
      );
      final retried = await study.studies.retrySave() as StudyDone;
      expect(retried.opened, studyRef('New'));
      expect(study.studies.canRetrySave, isFalse);
      expect(await pending.settle(), isNull);
      expect(
        study.store.documents.keys.where((r) => r.path.contains('/New')).length,
        1,
      );
    },
  );
  test(
    'linked prep study rename is refused before changing its file',
    () async {
      final people = MemoryPlayers();
      await people.savePlayer(
        Player({
          'id': 'one',
          'name': 'Opponent',
          'prep_file': studyRef('Endgames').path,
        }),
      );
      final study = await openStudy(twoChapterStudy, linkedPlayers: people);
      addTearDown(study.dispose);
      final result =
          await study.studies.rename(study.ref, 'Moved') as StudyProblem;
      expect(result.sentence, contains('linked'));
      expect(study.session.source, study.ref);
      expect(study.onDisk, twoChapterStudy);
    },
  );

  test('rename keeps the selected chapter and PGN bytes', () async {
    final study = await openStudy(twoChapterStudy, chapter: 1);
    addTearDown(study.dispose);
    final result = await study.studies.rename(study.ref, 'Renamed');
    expect(result, isA<StudyDone>());
    expect(study.session.source, studyRef('Renamed'));
    expect(study.session.game, 1);
    expect(
      (study.store.documents[studyRef('Renamed')] as Opened).text,
      twoChapterStudy,
    );
    expect(study.saver.referencesPending, isFalse);
  });
  test(
    'uncertain rename holds edits and exact retry releases the barrier',
    () async {
      final study = await openStudy(twoChapterStudy);
      addTearDown(study.dispose);
      study.store.moves.add(const IoFailure('interrupted'));
      expect(
        await study.studies.rename(study.ref, 'Renamed'),
        isA<StudyProblem>(),
      );
      expect(study.studies.canRetryRename, isTrue);
      expect(study.saver.takesWords, isFalse);
      expect(await study.studies.retryRename(), isA<StudyDone>());
      expect(study.session.source, studyRef('Renamed'));
      expect(study.studies.canRetryRename, isFalse);
      expect(study.saver.takesWords, isTrue);
    },
  );
  test(
    'a different rename while one is unconfirmed is refused, not retried',
    () async {
      final study = await openStudy(twoChapterStudy);
      addTearDown(study.dispose);
      study.store.moves.add(const IoFailure('interrupted'));
      expect(
        await study.studies.rename(study.ref, 'Renamed'),
        isA<StudyProblem>(),
      );
      final other =
          await study.studies.rename(study.ref, 'Other') as StudyProblem;
      expect(other.sentence, contains('pending study rename'));
      expect(study.session.source, study.ref);
      expect(study.onDisk, twoChapterStudy);
      expect(study.store.documents.containsKey(studyRef('Renamed')), isFalse);
      expect(study.store.documents.containsKey(studyRef('Other')), isFalse);
      expect(study.studies.canRetryRename, isTrue);
      expect(await study.studies.retryRename(), isA<StudyDone>());
      expect(study.session.source, studyRef('Renamed'));
    },
  );
  test(
    'renaming another study while one rename is unconfirmed is refused',
    () async {
      final study = await openStudy(twoChapterStudy);
      addTearDown(study.dispose);
      final second = studyRef('Second');
      study.store.documents[second] = Opened(
        threeChapterStudy,
        scriptedRevision(threeChapterStudy),
      );
      study.store.moves.add(const IoFailure('interrupted'));
      expect(
        await study.studies.rename(study.ref, 'Renamed'),
        isA<StudyProblem>(),
      );
      expect(await study.studies.rename(second, 'Other'), isA<StudyProblem>());
      expect(study.onDisk, twoChapterStudy);
      expect((study.store.documents[second] as Opened).text, threeChapterStudy);
      expect(study.store.documents.containsKey(studyRef('Renamed')), isFalse);
      expect(study.store.documents.containsKey(studyRef('Other')), isFalse);
      expect(study.studies.canRetryRename, isTrue);
    },
  );
  test('a rename the store recorded leaves nothing to ask about at exit and '
      'holds edits until the study follows it', () async {
    final writes = PendingWrites();
    final study = await openStudy(twoChapterStudy, pending: writes);
    addTearDown(study.dispose);
    study.store.moves
      ..add(const Unfinished('held open by another program'))
      ..add(const IoFailure('still finishing'));
    expect(
      await study.studies.rename(study.ref, 'Renamed'),
      isA<StudyProblem>(),
    );
    expect(await writes.settle() ?? '', isNot(contains('Rename study')));
    expect(study.studies.canRetryRename, isTrue);
    expect(study.saver.takesWords, isFalse);
    // Still owed when asked again: not asked about at exit either.
    expect(await study.studies.retryRename(), isA<StudyProblem>());
    expect(await writes.settle() ?? '', isNot(contains('Rename study')));
    expect(await study.studies.rename(study.ref, 'Renamed'), isA<StudyDone>());
    expect(study.session.source, studyRef('Renamed'));
    expect(study.studies.canRetryRename, isFalse);
    expect(study.saver.takesWords, isTrue);
  });
  test('on disk, a study follows a rename the store recorded once recovery '
      'finishes it, and takes the next edit at the new name', () async {
    final disk = await StoreFixture.create();
    addTearDown(disk.dispose);
    var held = true;
    final store = PgnFileStore(
      documents: disk.documents,
      support: disk.support,
      relocationHook: (step) async {
        if (held && step == FileRelocationStep.reviews) {
          throw const FileSystemException('held open by another program');
        }
      },
    );
    final root = p.join(disk.documents.path, 'studies');
    final from = ChapterRef.at(p.join(root, 'Endgames.pgn'));
    final to = ChapterRef.at(p.join(root, 'Renamed.pgn'));
    await disk.put(from, twoChapterStudy);
    final writes = PendingWrites();
    final saver = DocumentSaver(store, delay: Duration.zero);
    final session = DocumentSession(store, saver);
    final studies = Studies(
      pendingWrites: writes,
      files: ScriptedStudyFiles(StudiesListed([from])),
      documents: store,
      session: session,
      saver: saver,
      lichess: ScriptedLichess(
        const StudyNotFetched(StudyFetchProblem.unreachable),
      ),
      root: root,
    );
    addTearDown(() {
      studies.dispose();
      session.dispose();
      saver.dispose();
    });
    await studies.refresh();
    await session.open(from, game: 0);

    expect(await studies.rename(from, 'Renamed'), isA<StudyProblem>());
    expect(await writes.settle() ?? '', isNot(contains('Rename study')));
    expect(saver.takesWords, isFalse);
    held = false;
    // Any access naming either path finishes the recorded move.
    expect(await store.open(to), isA<Opened>());
    expect(await store.open(from), isA<Absent>());

    expect(await studies.retryRename(), isA<StudyDone>());
    expect(session.source, to);
    expect(saver.takesWords, isTrue);
    final edited = twoChapterStudy.replaceFirst('2. Nf3', '2. Nc3');
    saver.save(edited, const WholeDocument());
    await saver.flush();
    expect(saver.state, isNot(isA<SaveConflict>()));
    expect(saver.settled, isTrue);
    expect((await store.open(to) as Opened).text, edited);
    expect(await store.open(from), isA<Absent>());
    expect(await writes.settle(), isNull);
  }, skip: !Platform.isLinux);
  test('the same rename asked again retries the unconfirmed one', () async {
    final study = await openStudy(twoChapterStudy);
    addTearDown(study.dispose);
    study.store.moves.add(const IoFailure('interrupted'));
    expect(
      await study.studies.rename(study.ref, 'Renamed'),
      isA<StudyProblem>(),
    );
    expect(await study.studies.rename(study.ref, 'Renamed'), isA<StudyDone>());
    expect(study.session.source, studyRef('Renamed'));
    expect(study.studies.canRetryRename, isFalse);
  });
  test('linked prep study delete is refused and the file stays', () async {
    final people = MemoryPlayers();
    await people.savePlayer(
      Player({
        'id': 'one',
        'name': 'Opponent',
        'prep_file': studyRef('Endgames').path,
      }),
    );
    final study = await openStudy(twoChapterStudy, linkedPlayers: people);
    addTearDown(study.dispose);
    final result = await study.studies.delete(study.ref) as StudyProblem;
    expect(result.sentence, contains('Opponent'));
    expect(result.sentence, contains('deleting'));
    expect(study.store.documents.containsKey(study.ref), isTrue);
    expect(study.session.source, study.ref);
  });
  test(
    'chapters added while the study is being opened are what it shows',
    () async {
      final study = await openStudy(twoChapterStudy);
      addTearDown(study.dispose);
      final other = studyRef('Openings');
      final text = newStudyText(study: 'Openings', chapter: 'Intro');
      study.store.documents[other] = Opened(text, scriptedRevision(text));
      final gate = Completer<void>();
      study.store.readEarly = gate;
      final reads = study.store.opens;
      final opening = study.session.open(other, game: 0);
      while (study.store.opens == reads) {
        await pumpEventQueue();
      }
      final added = await study.studies.addChapters(IntoStudy(other), [
        ChapterDraft(
          name: 'Added',
          orientation: Side.white,
          moves: lineTree(Fen.initial, ['d4']),
        ),
      ]);
      expect(added, isA<StudyDone>());
      gate.complete();
      await opening;
      expect(study.session.source, other);
      expect(study.session.chapter!.lines, hasLength(2));
      study.session.playMove('e2e4');
      await study.saver.flush();
      expect(study.saver.state, isNot(isA<SaveConflict>()));
      expect(
        (study.store.documents[other] as Opened).text,
        contains('[ChapterName "Added"]'),
      );
    },
  );
  test('a study deleted while it is being opened does not open', () async {
    final study = await openStudy(twoChapterStudy);
    addTearDown(study.dispose);
    final other = studyRef('Openings');
    final text = newStudyText(study: 'Openings', chapter: 'Intro');
    study.store.documents[other] = Opened(text, scriptedRevision(text));
    final gate = Completer<void>();
    study.store.readEarly = gate;
    final reads = study.store.opens;
    final opening = study.session.open(other, game: 0);
    while (study.store.opens == reads) {
      await pumpEventQueue();
    }
    expect(await study.studies.delete(other), isA<StudyDone>());
    gate.complete();
    expect(await opening, isNot(isA<DocumentOpened>()));
    expect(study.session.source, isNot(other));
  });
  test('name collision does not leave a pending rename barrier', () async {
    final study = await openStudy(twoChapterStudy);
    addTearDown(study.dispose);
    study.store.moves.add(const Collision());
    expect(await study.studies.rename(study.ref, 'Taken'), isA<StudyProblem>());
    expect(study.studies.canRetryRename, isFalse);
    expect(study.saver.referencesPending, isFalse);
    expect(study.session.source, study.ref);
  });

  late StudyFixture study;

  setUp(() async {
    study = await openStudy(twoChapterStudy);
  });

  tearDown(() => study.dispose());

  /// What the folder would list after whatever was just written.
  void relist() {
    study.files.listing = StudiesListed([
      for (final ref in study.store.documents.keys) studyRef(_nameOf(ref)),
    ]);
  }

  test('the list: shows the studies in the folder and searches them', () {
    study.files.listing = StudiesListed([
      studyRef('Endgames'),
      studyRef('Openings'),
    ]);
    expect(study.studies.visible, hasLength(1));
    study.studies.search('open');
    expect(study.studies.visible, isEmpty);
  });

  test(
    'the list: a folder it could not read says so rather than showing nothing',
    () async {
      study.files.listing = const StudiesUnreadable('permission denied');
      await study.studies.refresh();
      expect(study.studies.state, isA<StudiesLoadFailed>());
      expect(study.studies.studies, isEmpty);
    },
  );

  test('the list: knows which study and chapter are open', () {
    expect(study.studies.open, study.ref);
    expect(study.studies.openChapter, 0);
    expect(study.studies.chapters.first.name, 'Rook endings');
  });

  test('making a study: writes a file with one chapter in it', () async {
    relist();
    final result = await study.studies.create('Openings');
    expect(result, isA<StudyDone>());
    final written = study.store.documents[studyRef('Openings')];
    expect((written as Opened).text, contains('[ChapterName "Chapter 1"]'));
    expect(written.text, contains('[StudyName "Openings"]'));
    expect((result as StudyDone).opened?.name, 'Openings');
  });

  test('making a study: a name already taken replaces nothing', () async {
    relist();
    final result = await study.studies.create('Endgames');
    expect(
      (result as StudyProblem).sentence,
      'A study named "Endgames" already exists.',
    );
    expect(study.onDisk, twoChapterStudy);
  });

  test('deleting a study: goes to recovery and closes the workspace', () async {
    relist();
    expect(await study.studies.delete(study.ref), isA<StudyDone>());
    expect(study.store.documents.containsKey(study.ref), isFalse);
    expect(study.session.source, isNull);
  });

  test(
    'deleting a study: a study that changed on disk is refused, and stays',
    () async {
      relist();
      study.store.deletes.add(const Conflict(null));
      final result = await study.studies.delete(study.ref);
      expect((result as StudyProblem).sentence, contains('changed on disk'));
      expect(study.store.documents.containsKey(study.ref), isTrue);
    },
  );

  test(
    'deleting a study: a move played while it goes cannot make it refuse',
    () async {
      relist();
      study.store.hold = true;
      final deleting = study.studies.delete(study.ref);
      await pumpEventQueue();
      study.session.playMove('g1f3');
      await pumpEventQueue();
      study.store.hold = false;
      // A save that went out now would land before the delete.
      while (study.store.waiting > 0) {
        study.store.releaseLast();
        await pumpEventQueue();
      }
      expect(await deleting, isA<StudyDone>());
      expect(study.store.documents.containsKey(study.ref), isFalse);
      expect(study.session.source, isNull);
    },
  );

  const downloaded =
      '[Event "Sicilian: Najdorf"]\n[StudyName "Sicilian"]\n'
      '[ChapterName "Najdorf"]\n\n1. e4 c5 *\n';

  test(
    'importing: files the download under the name its tags give it',
    () async {
      study.lichess.answer = const StudyFetched(downloaded);
      relist();
      final result = await study.studies.importFromUrl(
        'lichess.org/study/abcd1234',
      );
      expect(result, isA<StudyDone>());
      expect((result as StudyDone).opened?.name, 'Sicilian');
      expect(study.lichess.asked.single.studyId, 'abcd1234');
    },
  );

  test(
    'importing: a name already taken gets a number, never an overwrite',
    () async {
      study.lichess.answer = const StudyFetched(
        '[Event "Endgames: More"]\n[StudyName "Endgames"]\n\n1. e4 *\n',
      );
      relist();
      final result = await study.studies.importFromUrl(
        'lichess.org/study/abcd1234',
      );
      expect((result as StudyDone).opened?.name, 'Endgames 2');
      expect(study.onDisk, twoChapterStudy);
    },
  );

  test(
    'importing: a link it does not know is refused without a request',
    () async {
      final result = await study.studies.importFromUrl('example.com/study/x');
      expect((result as StudyProblem).sentence, 'Not a Lichess study link.');
      expect(study.lichess.asked, isEmpty);
    },
  );

  test('importing: a failed download takes nothing away', () async {
    study.lichess.answer = const StudyNotFetched(StudyFetchProblem.unreachable);
    relist();
    final result = await study.studies.importFromUrl(
      'lichess.org/study/abcd1234',
    );
    expect((result as StudyProblem).sentence, contains('did not respond'));
    expect(study.studies.studies, hasLength(1));
    expect(study.onDisk, twoChapterStudy);
  });

  test('importing: a download with no games in it is not filed', () async {
    study.lichess.answer = const StudyFetched('not a game\n');
    relist();
    final result = await study.studies.importFromUrl(
      'lichess.org/study/abcd1234',
    );
    expect((result as StudyProblem).sentence, contains('empty'));
    expect(study.store.documents, hasLength(1));
  });

  test('copying: the study PGN is the whole file', () async {
    expect(await study.studies.pgnOfOpenStudy(), twoChapterStudy);
  });

  test('copying: a chapter PGN is that game alone', () async {
    final pgn = await study.studies.pgnOfChapter(1);
    expect(pgn, contains('[ChapterName "Pawn endings"]'));
    expect(pgn, isNot(contains('Rook endings')));
  });

  test('copying: a chapter nobody has is nothing to copy', () async {
    expect(await study.studies.pgnOfChapter(9), isNull);
  });

  test(
    'importing: a download that never answers stops being in the way',
    () async {
      study.lichess.answer = const StudyNotFetched(
        StudyFetchProblem.unreachable,
      );
      relist();
      await study.studies.importFromUrl('lichess.org/study/abcd1234');
      // The owner is free again, so the next thing the user asks for runs.
      expect(study.studies.busy, isFalse);
      expect(await study.studies.create('Openings'), isA<StudyDone>());
    },
  );

  test(
    'making a study: a name that would leave the folder is refused',
    () async {
      relist();
      final result = await study.studies.create('../../evil');
      expect(result, isA<StudyProblem>());
      expect(study.store.documents.keys.map((ref) => ref.path), [
        '$studiesRoot/Endgames.pgn',
      ]);
    },
  );

  test('importing: a study whose own name is a path is filed by its file '
      'name', () async {
    study.lichess.answer = const StudyFetched(
      '[Event "../../evil: One"]\n[StudyName "../../evil"]\n\n1. e4 *\n',
    );
    relist();
    final result = await study.studies.importFromUrl(
      'lichess.org/study/abcd1234',
    );
    expect(result, isA<StudyDone>());
    for (final ref in study.store.documents.keys) {
      expect(p.dirname(ref.path), studiesRoot);
    }
  });
}

String _nameOf(DocumentRef ref) =>
    ref.path.split('/').last.replaceAll('.pgn', '');
