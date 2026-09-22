import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:chess_auto_prep/features/training/controllers/training_settings_controller.dart';
import 'package:chess_auto_prep/infrastructure/training/preferences_training_settings.dart';
import 'package:chess_auto_prep/widgets/training/training_settings_panel.dart';
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
  testWidgets('study completion persists once before Next, then survives reload', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('trainer_auto_next', false);
    await prefs.setInt('trainer_move_speed_ms', 1);
    await prefs.setInt('trainer_training_depth', 10);
    await prefs.setBool('engine_lifecycle.toggle_on', false);
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
    await tester.tap(find.text('Learn').first);
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
    expect(session.settings.trainingDepth, 10);
    await tester.tap(find.byKey(const Key('view-settings-repertoireTrainer')));
    await tester.pumpAndSettle();
    final settingsScroll = find
        .descendant(
          of: find.byType(TrainingSettingsPanel),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Train the whole line'),
      200,
      scrollable: settingsScroll,
    );
    await tester.tap(find.text('Train the whole line'));
    await tester.pumpAndSettle();
    expect(session.configuration.committed.toSettings().trainingDepth, isNull);
    expect(
      session.settings.trainingDepth,
      10,
      reason: 'Saved edits must not change an admitted sitting.',
    );
    await tester.scrollUntilVisible(
      find.text('Saved changes apply to your next sitting.'),
      -200,
      scrollable: settingsScroll,
    );
    final view = RendererBinding.instance.renderViews.first;
    final image = await (view.debugLayer! as OffsetLayer).toImage(
      Offset.zero & view.size,
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File(
      '/tmp/renewal-training-shared-settings.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    await tester.tap(find.byTooltip('Close settings (Esc)'));
    await tester.pumpAndSettle();

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
    expect(session.settings.trainingDepth, 10);
    for (var i = 0; i < 120 && !session.waitingForUser; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    expect(
      session.waitingForUser,
      isTrue,
      reason: '${session.phase}: ${session.error} ${session.feedback}',
    );
    // Exercise the host keyboard route after the completed field is enabled
    // again; native test text input can retain its previous disabled client.
    final moveInput = tester.state<MoveInputWidgetState>(
      find.byType(MoveInputWidget),
    );
    expect(moveInput.typeCharacter('d'), isTrue);
    expect(moveInput.typeCharacter('4'), isTrue);
    for (
      var i = 0;
      i < 120 && find.byType(TrainingResultsPanel).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.byType(TrainingResultsPanel),
      findsOneWidget,
      reason:
          '${session.phase} ${session.currentLine?.moves} index=${session.currentMoveIndex}: ${session.error} ${session.feedback}',
    );
    for (var i = 0; i < 120 && !session.completionCommitted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(session.sessionCorrect, 2);
    history = (await reviews.loadHistory())
        .where((entry) => entry.repertoireId == file.path)
        .toList();
    expect(history, hasLength(2));
    expect(history.map((entry) => entry.lineId).toSet(), hasLength(2));
    session.stopSession();
    expect(session.settings.trainingDepth, isNull);
    final restarted = TrainingSettingsController(PreferencesTrainingSettings());
    await restarted.ensureLoaded();
    expect(restarted.committed.toSettings().trainingDepth, isNull);
    expect(restarted.committed.toSettings().moveSpeedMs, 1);
    restarted.dispose();
    await prefs.reload();
    expect(prefs.containsKey('trainer_training_depth'), isFalse);
    await session.loadRepertoire();
    expect(
      session.reviewMap.values.map((entry) => entry.passCount),
      everyElement(1),
    );
    expect(session.reviewMap, hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
