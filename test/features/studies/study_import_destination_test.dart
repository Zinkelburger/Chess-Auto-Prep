import 'dart:async';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/features/studies/models/study_document.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/scripted_document_store.dart';
import '../../support/study_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'slow source read cannot import into a subsequently opened study',
    () async {
      final store = Store();
      final pending = Completer<PgnOpenResult>();
      store.onOpen = (path) async => path == '/import.pgn'
          ? pending.future
          : PgnOpened(snapshot('[Event "Other"]\n\n1. d4 *', path: path));
      final study = StudyController(
        library: MemoryStudyLibrary(),
        documents: store,
      );
      final importing = study.importFile('/import.pgn');
      expect(await study.openStudy('/other.pgn'), isTrue);
      pending.complete(
        PgnOpened(snapshot('[Event "Late"]\n\n1. e4 *', path: '/import.pgn')),
      );
      expect(await importing, 0);
      expect(study.doc.toPgn(), isNot(contains('Late')));
      expect(study.doc.toPgn(), contains('d4'));
      study.dispose();
    },
  );

  test(
    'new-study selection refuses a file created while its picker was open',
    () async {
      final store = Store()
        ..onCreate = (_, _) async => const PgnNameCollision();
      final study = StudyController(
        library: MemoryStudyLibrary(),
        documents: store,
      );
      await expectLater(
        study.addChaptersToStudyFile('/raced.pgn', [
          StudyChapter.fromGameText('[Event "Added"]\n\n1. e4 *'),
        ], createOnly: true),
        throwsA(isA<StudyWriteException>()),
      );
      expect(store.creates, ['/raced.pgn']);
      expect(store.saves, isEmpty);
      expect(study.doc.toPgn(), isNot(contains('Added')));
      study.dispose();
    },
  );
}
