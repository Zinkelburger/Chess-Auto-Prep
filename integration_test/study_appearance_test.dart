import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/features/documents/widgets/move_text_viewport.dart';
import 'package:chess_auto_prep/features/settings/models/app_appearance.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/features/studies/models/study_workspace_snapshot.dart';
import 'package:chess_auto_prep/infrastructure/settings/shared_preferences_app_settings_repository.dart';
import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/screens/study_screen.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/pgn/comment_editor.dart';
import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'helpers/tactics_helpers.dart';

String _course() {
  final text = StringBuffer(
    '[Event "First chapter"]\n\n1. e4 e5 *\n\n'
    '[Event "Appearance chapter"]\n\n',
  );
  const moves = ['Nf3', 'Nf6', 'Ng1', 'Ng8'];
  for (var ply = 0; ply < 100; ply++) {
    if (ply.isEven) text.write('${ply ~/ 2 + 1}. ');
    text.write('${moves[ply % 4]} {Course note $ply.} ');
  }
  return '$text *';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Study follows app appearance while retaining chapter, cursor and inline draft',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final settings = SharedPreferencesAppSettingsRepository();
      await settings.appearance.setAppearance(AppAppearance.dark);
      await tester.pumpWidget(ChessAutoPrepApp(settings: settings));
      await tester.pumpAndSettle();
      await switchToMode(tester, 'Study');
      final screen = find.byType(StudyScreen);
      final study = tester.element(screen).read<StudyController>();
      final cursor = TreePath.from(List.filled(50, 0));
      await study.restoreWorkspace(
        StudyWorkspaceSnapshot(
          name: 'Appearance course',
          path: '',
          content: _course(),
          dirty: true,
          chapter: 1,
          cursor: cursor.toList(),
          flipped: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(study.chapterIndex, 1);
      expect(study.path, cursor);
      expect(study.autoSaveEnabled, isFalse);
      final editor = find.byType(InteractivePgnEditor);
      final editorState = tester.state(editor);
      final selectedChip = find.descendant(
        of: find.descendant(
          of: editor,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is KeyedSubtree &&
                widget.key is GlobalKey &&
                widget.child is MoveChip,
          ),
        ),
        matching: find.byType(MoveChip),
      );
      await tester.tap(selectedChip, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit Comment'));
      await tester.pumpAndSettle();
      final inlineEditor = find.byType(PgnCommentEditor);
      final field = find.descendant(
        of: inlineEditor,
        matching: find.byType(TextField),
      );
      const draft =
          'Keep this unsaved inline comment through appearance changes';
      await tester.enterText(field, draft);
      await tester.pumpAndSettle();
      final fieldController = tester.widget<TextField>(field).controller!;
      fieldController.selection = const TextSelection(
        baseOffset: 5,
        extentOffset: 17,
      );
      // Inline typing already updates the dirty document; Save closes the
      // inline editor. Theme changes must preserve both draft and document.
      final editedContent = study.doc.toPgn();
      expect(editedContent, contains(draft));
      final inlineState = tester.state(inlineEditor);
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(MoveTextViewport),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      scroll.position.jumpTo(48);
      await tester.pumpAndSettle();
      final offset = scroll.position.pixels;
      expect(offset, greaterThan(1));
      // The selected move can leave the mounted window while its inline
      // comment is open. Check resolved ink on a currently mounted row.
      final styledChip = find
          .descendant(of: editor, matching: find.byType(MoveChip))
          .first;
      final darkInk = tester.widget<MoveChip>(styledChip).sanStyle.color;

      Future<void> expectRetained(Brightness brightness) async {
        await tester.pumpAndSettle();
        expect(Theme.of(tester.element(screen)).brightness, brightness);
        expect(tester.state(editor), same(editorState));
        expect(tester.state(inlineEditor), same(inlineState));
        expect(
          tester.widget<TextField>(field).controller,
          same(fieldController),
        );
        expect(fieldController.text, draft);
        expect(
          fieldController.selection,
          const TextSelection(baseOffset: 5, extentOffset: 17),
        );
        expect(scroll.position.pixels, closeTo(offset, 1));
        expect(study.chapterIndex, 1);
        expect(study.path, cursor);
        expect(study.flipped, isTrue);
        expect(study.dirty, isTrue);
        expect(study.doc.toPgn(), editedContent);
        final chip = tester.widget<MoveChip>(styledChip);
        final colors = Theme.of(tester.element(styledChip)).colorScheme;
        expect(
          chip.sanStyle.color,
          anyOf(colors.onSurface, colors.onPrimaryContainer),
        );
        expect(tester.takeException(), isNull);
      }

      await expectRetained(Brightness.dark);
      await settings.appearance.setAppearance(AppAppearance.light);
      await expectRetained(Brightness.light);
      expect(
        tester.widget<MoveChip>(styledChip).sanStyle.color,
        isNot(darkInk),
      );
      await settings.appearance.setAppearance(AppAppearance.dark);
      await expectRetained(Brightness.dark);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await settings.appearance.setAppearance(AppAppearance.system);
      await expectRetained(Brightness.light);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await expectRetained(Brightness.dark);

      await tester.ensureVisible(find.byTooltip('Save comment'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save comment'));
      await tester.pumpAndSettle();
      expect(find.byType(PgnCommentEditor), findsNothing);
      expect(study.doc.toPgn(), contains(draft));
      expect(study.chapterIndex, 1);
      expect(study.path, cursor);
      expect(study.dirty, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
