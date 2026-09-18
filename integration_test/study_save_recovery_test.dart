import 'package:chess_auto_prep/features/studies/repositories/study_import_repository.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_import_controller.dart';
import 'dart:io';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/screens/study_screen.dart';
import 'package:chess_auto_prep/widgets/training/move_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'helpers/tactics_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'cached collection creates a native study without replacing its namesake',
    (tester) async {
      await pumpApp(tester);
      await switchToMode(tester, 'Study');
      final context = tester.element(find.byType(StudyScreen));
      final study = context.read<StudyController>();
      final importer = context.read<StudyImportController>();
      final name =
          'Imported collection ${DateTime.now().microsecondsSinceEpoch}';
      await study.newStudy(name);
      final original = File(study.title.filePath!);
      final originalBytes = await original.readAsBytes();
      await context.read<StudyImportRepository>().cacheGame(
        '972801',
        '[Event "Source"]\n[White "A"]\n[Black "B"]\n\n1. e4 e5 *',
      );
      final result = await importer.startCollectionDownload(
        gameIds: ['972801'],
        studyName: name,
      );
      await tester.pumpAndSettle();
      expect(result.failure, isNull);
      expect(result.studyPath, endsWith('$name (2).pgn'));
      expect(result.publication!.outcome, isA<PgnSaved>());
      expect(
        (result.publication!.outcome as PgnSaved).after.revision.nativeIdentity,
        isNot('legacy-content'),
      );
      expect(await original.readAsBytes(), originalBytes);
      await tester.tap(find.widgetWithText(SnackBarAction, 'Open'));
      for (
        var i = 0;
        i < 100 && study.title.filePath != result.studyPath;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(study.title.filePath, result.studyPath);
      expect(study.doc.toPgn(), contains('1. e4 e5'));
      expect(study.dirty, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'Study move edit, native conflict, retained reload and exclusive copy',
    (tester) async {
      await pumpApp(tester);
      await switchToMode(tester, 'Study');
      final study = tester
          .element(find.byType(StudyScreen))
          .read<StudyController>();
      final name = 'Recovery journey ${DateTime.now().microsecondsSinceEpoch}';
      await study.newStudy(name);
      await tester.pumpAndSettle();
      final original = File(study.doc.filePath!);
      final bytes = await original.readAsBytes();
      final input = find.descendant(
        of: find.byType(MoveInputWidget),
        matching: find.byType(TextField),
      );
      await tester.enterText(input, 'e4');
      await tester.pump();
      expect(study.doc.toPgn(), contains('e4'));
      final replacement = File('${original.path}.replacement');
      await replacement.writeAsBytes(bytes);
      await replacement.rename(original.path);
      await tester.tap(find.byKey(const ValueKey('study-save-recovery')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('document-save')));
      for (var i = 0; i < 100 && study.state.outcome is! PgnConflict; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(study.state.outcome, isA<PgnConflict>());
      expect(await original.readAsBytes(), bytes);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reload and keep draft'));
      for (var i = 0; i < 100 && study.state.retainedDrafts.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(study.state.retainedDrafts.single.content, contains('e4'));
      expect(study.doc.toPgn(), isNot(contains('e4')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore retained draft'));
      await tester.pumpAndSettle();
      expect(study.doc.toPgn(), contains('e4'));
      await tester.tap(find.byKey(const ValueKey('study-save-recovery')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('document-save-copy')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '$name copy');
      await tester.tap(find.widgetWithText(FilledButton, 'Save a copy…'));
      for (var i = 0; i < 100 && study.doc.filePath == original.path; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(study.doc.filePath, isNot(original.path));
      expect(await File(study.doc.filePath!).readAsString(), contains('e4'));
      expect(await original.readAsBytes(), bytes);
      expect(study.dirty, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
