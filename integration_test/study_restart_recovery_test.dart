import 'package:chess_auto_prep/infrastructure/studies/study_recovery_codec.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/features/documents/controllers/workspace_recovery_controller.dart';
import 'package:chess_auto_prep/features/studies/models/study_workspace_snapshot.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/documents/file_workspace_recovery_store.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/screens/study_screen.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/engine/inline_engine_bar.dart';
import 'package:chess_auto_prep/widgets/study/study_board_pane.dart';
import 'package:chess_auto_prep/widgets/study/study_chapter_sidebar.dart';
import 'package:chess_auto_prep/widgets/app_mode_switcher.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'startup recovery restores native draft, rejects changed source and saves a copy',
    (tester) async {
      final root = await Directory(
        '${(await AppPaths.supportDirectory()).path}/recovery-journey',
      ).create(recursive: true);
      final folder = await Directory(
        '${root.path}/${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final file = File('${folder.path}/Original.pgn');
      const original = '[Event "Original"]\n\n1. e4 *';
      await file.writeAsString(original);
      final documents = NativePgnDocumentStore();
      final baseline = (await documents.open(file.path) as PgnOpened).snapshot;
      final firstStore = FileWorkspaceRecoveryStore<StudyWorkspaceSnapshot>(
        codec: const StudyRecoveryCodec(),
        directory: () async => folder,
      );
      await firstStore.write(
        StudyWorkspaceSnapshot(
          name: 'Recovered study',
          path: file.path,
          content: '[Event "Original"]\n\n1. e4 {Recovered note} e5 *',
          dirty: true,
          baseline: baseline,
          cursor: [0, 0],
          flipped: true,
        ),
      );
      await firstStore.close();
      const external = '[Event "External change"]\n\n1. d4 *';
      await file.writeAsString(external);
      final restartStore = FileWorkspaceRecoveryStore<StudyWorkspaceSnapshot>(
        codec: const StudyRecoveryCodec(),
        directory: () async => folder,
      );
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        ChessAutoPrepApp(studyRecoveryStore: restartStore),
      );
      await tester.pumpAndSettle();
      for (
        var i = 0;
        i < 100 &&
            find
                .byKey(const ValueKey('review-study-recovery'))
                .evaluate()
                .isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.byKey(const ValueKey('review-study-recovery')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore draft'));
      for (
        var i = 0;
        i < 100 && find.byType(StudyScreen).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(StudyScreen));
      final study = context.read<StudyController>();
      expect(study.doc.toPgn(), contains('Recovered note'));
      expect(study.path.length, 2);
      expect(study.flipped, isTrue);
      expect(study.autoSaveEnabled, isFalse);
      expect(await file.readAsString(), external);
      final recovered = study.doc;
      final boardFinder = find.descendant(
        of: find.byType(StudyBoardPane),
        matching: find.byType(ChessBoardWidget),
      );
      final chapterListFinder = find.descendant(
        of: find.byType(StudyChapterSidebar),
        matching: find.byType(ReorderableListView),
      );
      final beforeBoard = tester.widget(boardFinder);
      final beforeList = tester.widget(chapterListFinder);
      final beforeEngine = tester.widget(find.byType(InlineEngineBar));
      final commentField = find.descendant(
        of: find.byType(InteractivePgnEditor),
        matching: find.byType(TextField),
      );
      await tester.tap(commentField);
      await tester.enterText(commentField, 'Continued');
      await tester.pumpAndSettle();
      final editor = tester.state(
        find.descendant(
          of: find.byType(InteractivePgnEditor),
          matching: find.byType(EditableText),
        ),
      );
      await tester.enterText(commentField, 'Continued after recovery');
      await tester.pumpAndSettle();
      expect(
        tester.state(
          find.descendant(
            of: find.byType(InteractivePgnEditor),
            matching: find.byType(EditableText),
          ),
        ),
        same(editor),
      );
      expect(study.cursorComment, 'Continued after recovery');
      expect(tester.widget(boardFinder), same(beforeBoard));
      expect(tester.widget(chapterListFinder), same(beforeList));
      expect(tester.widget(find.byType(InlineEngineBar)), same(beforeEngine));
      expect(recovered.toPgn(), isNot(contains('Continued')));
      expect(await file.readAsString(), external);
      await tester.tap(find.byKey(const ValueKey('study-save-recovery')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('document-save')));
      for (var i = 0; i < 100 && study.state.outcome is! PgnConflict; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(study.state.outcome, isA<PgnConflict>());
      await tester.tap(find.byKey(const ValueKey('document-save-copy')));
      await tester.pumpAndSettle();
      final name = 'Restart recovered ${DateTime.now().microsecondsSinceEpoch}';
      await tester.enterText(find.byType(TextField).last, name);
      await tester.tap(find.widgetWithText(FilledButton, 'Save a copy…'));
      for (var i = 0; i < 100 && study.dirty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(study.dirty, isFalse);
      expect(
        await File(study.doc.filePath!).readAsString(),
        allOf(contains('Recovered note'), contains('Continued after recovery')),
      );
      expect(await file.readAsString(), external);
      await tester
          .element(find.byKey(AppModeSwitcher.switcherKey).first)
          .read<WorkspaceRecoveryController<StudyWorkspaceSnapshot>>()
          .flush();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
