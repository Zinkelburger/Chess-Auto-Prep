// What the Train tab sends to the rest of the window: a line read only
// when it opened; a course imported and trained, in the trainer from its
// own repertoire and elsewhere by its chapter; and a lesson studied on the
// Analysis tab, with the engine on only in the trainer, and not at all
// once the lesson is gone.
import 'package:chess_auto_prep/app/document_views.dart';
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/app/train_doors.dart';
import 'package:chess_auto_prep/features/trainer/trainer_state.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/workspace_tabs.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/window_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WindowFixture w;
  late TrainerView view;
  late TrainDoors doors;

  setUp(() async {
    w = WindowFixture();
    await w.requests.open(kidMain);
    w.requests.switchTo(Mode.trainer);
    view = TrainerView(
      w.parts.workspace,
      w.requests,
      w.parts.documents,
      w.lineTrainer,
    );
    doors = TrainDoors(
      requests: w.requests,
      workspace: w.parts.workspace,
      trainer: w.lineTrainer,
      view: () => view,
      mounted: () => true,
    );
    view.tabs.show(WorkspaceTab.train);
  });
  tearDown(() {
    view.dispose();
    w.dispose();
  });

  test('a line that does not open leaves the tabs as they were', () async {
    final gone = ref('KID', 'Gone');
    await doors.readLine((
      ref: gone,
      game: null,
      sans: const ['c5'],
      place: ReadIn.moves,
    ));
    expect(view.tabs.selected, WorkspaceTab.train);
  });

  group('a course', () {
    const course = '[Event "Italian"]\n[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6 *\n';

    void offer() {
      w.libraryPicker.answer = '/downloads/Italian.pgn';
      w.store.documents[const DocumentRef('/downloads/Italian.pgn')] = Opened(
        course,
        scriptedRevision(course),
        readOnly: 'outside Documents',
      );
      w.chapterFiles.listing = Repertoires([
        folder('benko', ['Main']),
        folder('KID', ['Main']),
        folder('Italian', ['Main']),
      ]);
    }

    test('not chosen, changes nothing', () async {
      view.tabs.show(WorkspaceTab.moves);
      final scope = w.lineTrainer.scope;
      await doors.importCourse();
      expect(view.tabs.selected, WorkspaceTab.moves);
      expect(w.lineTrainer.scope, scope);
    });

    test('in the trainer, is trained from its own repertoire', () async {
      offer();
      view.tabs.show(WorkspaceTab.moves);
      await doors.importCourse();
      await pumpEventQueue();
      expect(w.session.source?.path, '/repertoires/Italian/Main.pgn');
      expect(w.lineTrainer.selection.repertoire?.name, 'Italian');
      expect(view.tabs.selected, WorkspaceTab.train);
    });

    test('elsewhere, is trained by its chapter', () async {
      offer();
      w.requests.switchTo(Mode.study);
      w.lineTrainer.setScope(TrainScope.repertoire);
      await doors.importCourse();
      expect(w.lineTrainer.scope, TrainScope.chapter);
    });
  });

  group('a lesson studied', () {
    setUp(() async {
      await w.lineTrainer.reload();
      w.lineTrainer.learn();
      await pumpEventQueue();
      expect(w.lineTrainer.lesson, isNotNull);
    });

    test('comes up on the Analysis tab with the engine on', () async {
      await doors.studyLesson();
      expect(view.layout.isOpen(WorkspaceTab.analysis), isTrue);
      expect(w.analysis.enabled, isTrue);
    });

    test('outside the trainer, leaves the engine as it was', () async {
      w.requests.switchTo(Mode.study);
      await doors.studyLesson();
      expect(w.analysis.enabled, isFalse);
    });

    test('given up on the way, opens no tab', () async {
      final studying = doors.studyLesson();
      w.lineTrainer.leave();
      await studying;
      expect(view.layout.isOpen(WorkspaceTab.analysis), isFalse);
      expect(w.analysis.enabled, isFalse);
    });
  });
}
