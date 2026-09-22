import 'dart:async';
import 'package:chess_auto_prep/app/training_dependencies.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_board_controller.dart';
import 'package:chess_auto_prep/features/training/controllers/training_settings_controller.dart';
import 'package:chess_auto_prep/features/training/models/training_phase.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/widgets/training/training_results_panel.dart';
import 'package:chess_auto_prep/widgets/training/repertoire_selector_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/generation_artifacts_fixture.dart';
import '../../support/training_settings.dart';
import '../../services/training/training_fakes.dart';

class _Reviews extends FakeReviewService {
  final gate = Completer<void>();
  bool fail = false;
  @override
  Future<void> saveAll(
    List<RepertoireReviewEntry> entries, {
    String? repertoireId,
  }) async {
    await gate.future;
    if (fail) throw StateError('storage unavailable');
    await super.saveAll(entries, repertoireId: repertoireId);
  }
}

void main() {
  for (final automatic in [false, true]) {
    testWidgets(
      '${automatic ? 'automatic' : 'manual'} failure keeps Retry actionable without readmitting ratings',
      (tester) async {
        final reviews = _Reviews()..fail = true;
        reviews.gate.complete();
        final configuration = TrainingSettingsController(
          MemoryTrainingSettings(),
        );
        final session =
            createTrainingSession(
                artifacts: generationArtifactsFixture().repository,
                configuration: configuration,
                session: RepertoireBoardController(),
                repertoireService: FakeRepertoireService(),
                reviewService: reviews,
              )
              ..settings = TrainingSettings(
                autoNext: false,
                showRatingButtons: !automatic,
              );
        addTearDown(session.dispose);
        addTearDown(configuration.dispose);
        final line = fakeLine('line', ['e4']);
        session.lines = [line];
        session.isLoading = false;
        session.currentLine = line;
        session.completeLine();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListenableBuilder(
                listenable: session,
                builder: (_, _) => session.error == null
                    ? TrainingResultsPanel(session: session)
                    : RepertoireSelectorPanel(
                        isLoading: false,
                        hasLines: true,
                        canStartTraining: false,
                        error: session.error,
                        onRetry: session.retryFailure,
                        onSelectRepertoire: () {},
                      ),
              ),
            ),
          ),
        );
        if (!automatic) await tester.tap(find.text('Good'));
        await tester.pumpAndSettle();
        expect(find.text('Retry'), findsOneWidget);
        expect(find.text('Good'), findsNothing);
        expect(session.canRate, isFalse);
        expect(session.canAdvance, isFalse);
        session.nextLine();
        session.completeLine();
        await session.rateLine(ReviewRating.easy);
        expect(session.currentLine, same(line));
        expect(reviews.history, isEmpty);
        reviews.fail = false;
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Retry'), findsNothing);
        expect(find.text('Good'), findsNothing);
        expect(session.completionCommitted, isTrue);
        expect(reviews.history.single.rating, 'good');
        expect(session.sessionCorrect, 1);
        await session.progress.flushHeaders();
      },
    );
  }
  testWidgets(
    'results mount never rates; admitted rating disables Next until saved',
    (tester) async {
      final reviews = _Reviews();
      final configuration = TrainingSettingsController(
        MemoryTrainingSettings(),
      );
      final session = createTrainingSession(
        artifacts: generationArtifactsFixture().repository,
        configuration: configuration,
        session: RepertoireBoardController(),
        repertoireService: FakeRepertoireService(),
        reviewService: reviews,
      )..settings = TrainingSettings(autoNext: false);
      addTearDown(session.dispose);
      addTearDown(configuration.dispose);
      final line = fakeLine('line', ['e4']);
      session.lines = [line];
      session.isLoading = false;
      session.currentLine = line;
      session.phase = TrainingPhase.finished;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: session,
              builder: (_, _) => TrainingResultsPanel(session: session),
            ),
          ),
        ),
      );
      expect(find.text('How well did you know this?'), findsOneWidget);
      expect(session.completionBusy, isFalse);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Next Line'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Good'));
      await tester.pump();
      expect(find.text('Saving result…'), findsOneWidget);
      session.nextLine();
      expect(session.currentLine, same(line));
      reviews.gate.complete();
      await tester.pumpAndSettle();
      expect(session.completionCommitted, isTrue);
      expect(session.sessionCorrect, 1);
      expect(find.text('Good'), findsNothing);
      await tester.tap(find.text('Next Line'));
      await tester.pump();
      expect(session.runComplete, isTrue);
    },
  );
}
