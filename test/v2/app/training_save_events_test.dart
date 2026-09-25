import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/features/trainer/trainer.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

void main() {
  late WindowFixture app;
  late Trainer trainer;
  setUp(() async {
    app = WindowFixture();
    await app.library.refresh();
    await app.session.open(kidMain);
    trainer = app.lineTrainer;
    app.chapterFiles.validateWith = (_, observed) async {
      for (final entry in observed.entries) {
        final current = await app.store.open(DocumentRef(entry.key));
        if (current is! Opened ||
            !sameChapterRevision(current.revision, entry.value)) {
          return const RepertoireChanged();
        }
      }
      return const RepertoireCurrent();
    };
    await trainer.reload();
    trainer.learn();
    expect(trainer.lesson, isNotNull);
  });
  tearDown(() => app.dispose());

  Future<void> outsideSave() async {
    final before = await app.parts.env.store.open(kidMain) as Opened;
    await app.parts.env.store.save(
      kidMain,
      '${before.text}\n',
      expected: before.revision,
      scope: const WholeDocument(),
    );
  }

  test('another writer cannot masquerade as the editor autosave', () async {
    await outsideSave();
    await app.parts.catalog.synchronize();
    await pumpEventQueue();
    expect(trainer.lesson, isNull);
    expect(trainer.state, isA<TrainerFailed>());
  });

  test(
    'a writer during a guard needs the matching adopted source proof',
    () async {
      await trainer.pauseForWrite();
      await outsideSave();
      trainer.resumeAfterWrite();
      await app.parts.catalog.synchronize();
      await pumpEventQueue();
      expect(trainer.lesson, isNull);
      expect(trainer.state, isA<TrainerFailed>());
    },
  );

  test(
    'the editor own acknowledged save preserves its current progress owner',
    () async {
      app.session.setComment(NodePath.root(), 'A saved note');
      await pumpEventQueue();
      final previous = (trainer.state as TrainerReady).progress;
      trainer.learn();
      final lesson = trainer.lesson;
      await app.saver.flush();
      await app.parts.catalog.synchronize();
      await pumpEventQueue();
      expect((trainer.state as TrainerReady).progress, same(previous));
      expect(trainer.lesson, same(lesson));
      expect(
        app.session.trainingSourceRevision,
        app.saver.lastReceipt!.committed,
      );
    },
  );
}
