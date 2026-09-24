import 'package:chess_auto_prep/v2/features/library/library_state.dart';
import 'package:chess_auto_prep/v2/features/trainer/trainer.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_store.dart';
import '../support/window_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'inactive chapter rename and deletion propagate to repertoire training',
    () async {
      final app = WindowFixture();
      addTearDown(app.dispose);
      final b = ChapterRef.at('/repertoires/KID/B.pgn');
      final renamed = ChapterRef.at('/repertoires/KID/Renamed.pgn');
      app.store.documents[b] = Opened(
        blackChapter,
        scriptedRevision(blackChapter),
      );
      void listing(List<ChapterRef> chapters) {
        app.chapterFiles.listing = Repertoires([
          RepertoireFolder(
            name: 'KID',
            path: '/repertoires/KID',
            modified: DateTime(2026),
            chapters: chapters,
          ),
        ]);
      }

      listing([kidMain, b]);
      await app.library.refresh();
      await app.session.open(kidMain);
      app.lineTrainer.setScope(TrainScope.repertoire);
      await app.lineTrainer.reload();
      List<String> sources() => (app.lineTrainer.state as TrainerReady).chapters
          .map((chapter) => chapter.ref.path)
          .toList();
      expect(sources(), [kidMain.path, b.path]);

      listing([kidMain, renamed]);
      expect(await app.library.renameChapter(b, 'Renamed'), isA<LibraryDone>());
      await pumpEventQueue();
      expect(
        app.session.source,
        kidMain,
        reason: 'the active document did not change',
      );
      expect(sources(), [kidMain.path, renamed.path]);

      listing([kidMain]);
      expect(await app.library.deleteChapter(renamed), isA<LibraryDone>());
      await pumpEventQueue();
      expect(sources(), [kidMain.path]);
    },
  );
}
