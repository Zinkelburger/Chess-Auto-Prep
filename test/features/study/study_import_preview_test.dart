import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/features/study/studies.dart';
import 'package:chess_auto_prep/features/study/study_import_source.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/study_fixture.dart';

void main() {
  test(
    'preview writes nothing, append keeps unsaved comments and can be undone',
    () async {
      final study = await openStudy(twoChapterStudy);
      addTearDown(study.dispose);
      final data =
          await study.studies.imports.pgn('[Event "New"]\n\n1. c4 e5 *\n')
              as StudyImportData;
      expect(study.store.documents, hasLength(1));
      study.session.setComment(NodePath.of([0]), 'Keep this note');
      final result =
          await study.studies.importPreview(data, into: study.ref) as StudyDone;
      expect(result.chapter, 2);
      expect(study.session.chapter!.lines, hasLength(3));
      expect(
        study.session.chapter!.lines.first.text,
        contains('Keep this note'),
      );
      await study.saver.flush();
      await study.session.undo();
      expect(study.session.chapter!.lines, hasLength(2));
      expect(
        study.onDisk,
        twoChapterStudy,
        reason: 'undo restores the pre-autosave batch',
      );
    },
  );

  test(
    'partial PGN is preserved in a new study and cannot be appended',
    () async {
      final study = await openStudy(twoChapterStudy);
      addTearDown(study.dispose);
      const text =
          '[Event "Valid"]\n\n1. e4 *\n\n[Event "Broken"]\n\n1. d4 e9 *\n';
      final data = await study.studies.imports.pgn(text) as StudyImportData;
      expect(data.complete, isFalse);
      expect(
        await study.studies.importPreview(data, into: study.ref),
        isA<StudyProblem>(),
      );
      expect(study.session.chapter!.lines, hasLength(2));
      final result =
          await study.studies.importPreview(data, name: 'Preserved')
              as StudyDone;
      expect((study.store.documents[result.opened] as Opened).text, text);
    },
  );
}
