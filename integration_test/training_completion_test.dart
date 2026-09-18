import 'dart:io';

import 'package:chess_auto_prep/services/repertoire_review_service.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/widgets/training/move_input_widget.dart';
import 'package:chess_auto_prep/widgets/training/training_results_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/board_helpers.dart';
import 'helpers/tactics_helpers.dart';

Future<void> ready(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 120 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'study completion persists once before Next, then survives reload',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('trainer_auto_next', false);
      await prefs.setInt('trainer_move_speed_ms', 1);
      final root = await AppPaths.studiesDirectory(create: true);
      final file = File(
        p.join(
          root.path,
          'Completion ${DateTime.now().microsecondsSinceEpoch}.pgn',
        ),
      );
      await file.writeAsString(
        '[Event "First completion"]\n[Result "*"]\n\n1. e4 *\n\n[Event "Second completion"]\n[Result "*"]\n\n1. d4 *\n',
      );
      addTearDown(() => file.delete());
      await pumpApp(tester);
      getAppState(tester).switchToStudyTraining(path: file.path);
      await ready(tester, find.text('Learn'));
      await tester.tap(find.text('Learn'));
      await ready(tester, find.byType(MoveInputWidget));
      final input = find.descendant(
        of: find.byType(MoveInputWidget),
        matching: find.byType(TextField),
      );
      await tester.enterText(input, 'e4');
      await ready(tester, find.byType(TrainingResultsPanel));
      final session = tester
          .widget<TrainingResultsPanel>(find.byType(TrainingResultsPanel))
          .session;
      for (var i = 0; i < 120 && !session.completionCommitted; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(session.completionCommitted, isTrue);
      expect(session.sessionCorrect, 1);
      final firstId = session.currentLine!.persistedId;
      final reviews = RepertoireReviewService();
      var history = (await reviews.loadHistory())
          .where((entry) => entry.repertoireId == file.path)
          .toList();
      expect(history, hasLength(1));
      expect(history.single.lineId, firstId);
      session.completeLine();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Next puzzle'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(session.currentLine!.persistedId, isNot(firstId));
      await tester.enterText(input, 'd4');
      await ready(tester, find.byType(TrainingResultsPanel));
      for (var i = 0; i < 120 && !session.completionCommitted; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(session.sessionCorrect, 2);
      history = (await reviews.loadHistory())
          .where((entry) => entry.repertoireId == file.path)
          .toList();
      expect(history, hasLength(2));
      expect(history.map((entry) => entry.lineId).toSet(), hasLength(2));
      await session.loadRepertoire();
      expect(
        session.reviewMap.values.map((entry) => entry.passCount),
        everyElement(1),
      );
      expect(session.reviewMap, hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
