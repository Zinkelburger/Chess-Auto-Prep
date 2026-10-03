import 'package:chess_auto_prep/storage/training_records.dart'
    show NothingToRepoint;
import 'package:chess_auto_prep/net/lichess_studies.dart';
import 'dart:io';

import 'package:chess_auto_prep/features/study/studies.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/recovery_gate.dart';
import 'package:chess_auto_prep/storage/study_files.dart';
import 'package:chess_auto_prep/workspace/document_saver.dart';
import 'package:chess_auto_prep/workspace/document_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../storage/store_fixture.dart';
import '../../support/scripted_store.dart';
import '../../support/study_fixture.dart';

void main() {
  test(
    'delete, list and restore as preserve exact PGN bytes and never overwrite',
    () async {
      final disk = await StoreFixture.create();
      addTearDown(disk.dispose);
      final root = Directory(p.join(disk.documents.path, 'studies'));
      final ref = ChapterRef.at(p.join(root.path, 'Endgames.pgn'));
      await disk.put(ref, twoChapterStudy);
      final files = StudyDirectory(
        root,
        recovery: RecoveryGate(
          documents: disk.documents,
          support: disk.support,
        ),
      );
      final saver = DocumentSaver(disk.store);
      final session = DocumentSession(disk.store, saver);
      final studies = Studies(
        files: files,
        documents: disk.store,
        session: session,
        saver: saver,
        lichess: ScriptedLichess(
          const StudyNotFetched(StudyFetchProblem.unreachable),
        ),
        root: root.path,
      );
      addTearDown(() {
        studies.dispose();
        session.dispose();
        saver.dispose();
      });
      await session.open(ref, game: 1);
      expect(await studies.delete(ref), isA<StudyDone>());
      final deleted =
          (await studies.deleted() as DeletedChapters).chapters.single;
      expect(deleted.name, 'Endgames');
      expect(await File(deleted.path).readAsString(), twoChapterStudy);
      await disk.put(ref, '[Event "Keep"]\n\n1. d4 *\n');
      expect(await studies.restore(deleted), isA<StudyProblem>());
      expect(await File(ref.path).readAsString(), contains('Keep'));
      expect(
        await studies.restore(deleted, name: 'Recovered'),
        isA<StudyDone>(),
      );
      expect(
        await File(p.join(root.path, 'Recovered.pgn')).readAsString(),
        twoChapterStudy,
      );
      expect((await studies.deleted() as DeletedChapters).chapters, isEmpty);
      expect(session.source, isNull);
    },
  );

  test(
    'uncertain restore can retry after the original recovery file disappears',
    () async {
      final pending = PendingWrites();
      final study = await openStudy(twoChapterStudy, pending: pending);
      addTearDown(study.dispose);
      final deleted = DeletedChapter(
        path: '/studies/.cap-pgn-history/old.pgn',
        folder: '/studies',
        name: 'Old',
        deletedAt: DateTime(2026),
      );
      final source = ChapterRef.at(deleted.path);
      final revision = scriptedRevision(twoChapterStudy);
      study.store.documents[source] = Opened(twoChapterStudy, revision);
      study.store.moves.add(const IoFailure('lost acknowledgment'));
      expect(await study.studies.restore(deleted), isA<StudyProblem>());
      expect(study.studies.canRetryRestore, isTrue);
      study.store.documents.remove(source);
      study.store.moves.add(
        Moved(revision, training: const NothingToRepoint()),
      );
      final reads = study.store.opens;
      expect(await study.studies.retryRestore(), isA<StudyDone>());
      expect(
        study.store.opens,
        reads,
        reason: 'retry uses the retained move, not a reread',
      );
      expect(study.studies.canRetryRestore, isFalse);
      expect(await pending.settle(), isNull);
      expect(study.session.source, study.ref);
    },
  );
}
