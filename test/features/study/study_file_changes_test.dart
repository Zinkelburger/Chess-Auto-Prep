// Renaming, restoring and deleting study files through the studies owner:
// the cases about which file a change may touch.

import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/features/study/studies_state.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/deleted_chapters.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:chess_auto_prep/storage/study_files.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/study_fixture.dart';

const _otherText = '''
[Event "Openings: Alpha"]
[StudyName "Openings"]
[ChapterName "Alpha"]

1. e4 *
''';

DeletedChapter _deletedAt(String path, {String folder = studiesRoot}) =>
    DeletedChapter(
      path: path,
      folder: folder,
      name: 'Old',
      deletedAt: DateTime.utc(2026, 11, 2),
    );

void main() {
  test('a study a group in Players & prep links to is not deleted', () async {
    final people = MemoryPlayers();
    await people.saveGroup(
      PlayerGroup({
        'id': 'club',
        'name': 'Club championship',
        'study': studyRef('Endgames').path,
      }),
    );
    final study = await openStudy(twoChapterStudy, linkedPlayers: people);
    addTearDown(study.dispose);

    final result = await study.studies.delete(study.ref) as StudyProblem;
    expect(result.sentence, contains('Club championship'));
    expect(study.store.documents.containsKey(study.ref), isTrue);
  });

  test('a group linked to another study does not stop a delete', () async {
    final people = MemoryPlayers();
    await people.saveGroup(
      PlayerGroup({
        'id': 'club',
        'name': 'Club championship',
        'study': studyRef('Openings').path,
      }),
    );
    final study = await openStudy(twoChapterStudy, linkedPlayers: people);
    addTearDown(study.dispose);

    expect(await study.studies.delete(study.ref), isA<StudyDone>());
    expect(study.store.documents.containsKey(study.ref), isFalse);
  });

  test('an unconfirmed rename of a study that is not open is finished by '
      'its retry', () async {
    final study = await openStudy(twoChapterStudy);
    addTearDown(study.dispose);
    final other = studyRef('Openings');
    study.store.documents[other] = Opened(
      _otherText,
      scriptedRevision(_otherText),
    );
    study.files.listing = StudiesListed([study.ref, other]);
    await study.studies.refresh();

    study.store.moves.add(const IoFailure('interrupted'));
    expect(await study.studies.rename(other, 'Old'), isA<StudyProblem>());
    expect(study.studies.canRetryRename, isTrue);

    expect(await study.studies.retryRename(), isA<StudyDone>());
    expect(study.store.documents.containsKey(studyRef('Old')), isTrue);
    expect(study.store.documents.containsKey(other), isFalse);
    expect(study.session.source, study.ref, reason: 'the open study stays');
  });

  group('restoring', () {
    const inRecovery = '$studiesRoot/$recoveryFolder/Old.pgn';

    test('a deleted file that is not in the studies\' recovery folder is '
        'refused and stays where it is', () async {
      final study = await openStudy(twoChapterStudy);
      addTearDown(study.dispose);
      const elsewhere = '/books/$recoveryFolder/Old.pgn';
      study.store.documents[ChapterRef.at(elsewhere)] = Opened(
        _otherText,
        scriptedRevision(_otherText),
      );

      final result =
          await study.studies.restore(_deletedAt(elsewhere)) as StudyProblem;
      expect(
        result.sentence,
        'That deleted study is outside the studies folder.',
      );
      expect(study.store.documents, contains(ChapterRef.at(elsewhere)));
      expect(study.store.documents.containsKey(studyRef('Old')), isFalse);
    });

    test('while a restore is unconfirmed, the same restore asked again '
        'retries it and another name is refused', () async {
      final study = await openStudy(twoChapterStudy);
      addTearDown(study.dispose);
      final source = ChapterRef.at(inRecovery);
      study.store.documents[source] = Opened(
        _otherText,
        scriptedRevision(_otherText),
      );
      final deleted = _deletedAt(inRecovery);

      study.store.moves.add(const IoFailure('lost acknowledgment'));
      expect(await study.studies.restore(deleted), isA<StudyProblem>());
      expect(study.studies.canRetryRestore, isTrue);

      final other =
          await study.studies.restore(deleted, name: 'Renamed') as StudyProblem;
      expect(other.sentence, 'Retry the pending study save first.');
      expect(study.store.documents.containsKey(studyRef('Renamed')), isFalse);

      expect(await study.studies.restore(deleted), isA<StudyDone>());
      expect(study.store.documents.containsKey(studyRef('Old')), isTrue);
      expect(study.store.documents.containsKey(source), isFalse);
      expect(study.studies.canRetryRestore, isFalse);
    });
  });
}
