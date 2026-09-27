import 'dart:async';
import 'dart:io';
import 'package:chess_auto_prep/v2/chess/pgn/study.dart';
import 'package:chess_auto_prep/v2/storage/pgn_export.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/storage/player_files.dart';
import 'package:chess_auto_prep/v2/chess/players/player.dart';
import '../../support/viewer_fixture.dart';
import '../../support/scripted_store.dart';
import 'package:chess_auto_prep/v2/features/study/studies.dart';
import 'package:chess_auto_prep/v2/net/lichess_studies.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/study_files.dart';
import 'package:flutter_test/flutter_test.dart';

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
        ..copyTo = '/Documents/pgn_collections/Imported.pgn';
      final study = await openStudy(
        twoChapterStudy,
        picker: picker,
        importer: importer,
      );
      addTearDown(study.dispose);
      final source = DocumentRef(importer.copyTo!);
      study.store.documents[source] = Opened(
        twoChapterStudy,
        scriptedRevision(twoChapterStudy),
      );
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
