import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/models/training_settings.dart';
import 'package:chess_auto_prep/services/repertoire_review_service.dart';
import 'package:chess_auto_prep/services/training/training_phase.dart';
import 'package:chess_auto_prep/widgets/training/training_results_panel.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _line = RepertoireLine(
  id: 'L',
  name: 'Line L',
  moves: const ['e4', 'e5'],
  color: 'white',
  startPosition: Chess.initial,
  fullPgn: '',
);

/// The panel right after a line finished, with rating left to the panel.
Widget _finished({
  required bool hadLearnPhase,
  required bool hadMistake,
  required void Function(ReviewRating) onRate,
}) {
  return MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: TrainingResultsPanel(
        phase: TrainingPhase.finished,
        currentLine: _line,
        dueQueue: [_line],
        reviewMap: const {},
        repertoireId: 'rep',
        lineHadMistake: hadMistake,
        hadLearnPhaseThisSession: hadLearnPhase,
        settings: TrainingSettings(),
        sessionCorrect: 0,
        sessionIncorrect: 0,
        sessionStreak: 0,
        reviewService: RepertoireReviewService(),
        onRateLine: onRate,
        onNextLine: () {},
      ),
    ),
  );
}

void main() {
  group('TrainingResultsPanel after the learn walkthrough', () {
    testWidgets('a clean first drill is rated Good on its own', (tester) async {
      final ratings = <ReviewRating>[];
      await tester.pumpWidget(
        _finished(hadLearnPhase: true, hadMistake: false, onRate: ratings.add),
      );
      await tester.pump();

      expect(find.text('Line learned — continuing...'), findsOneWidget);
      expect(ratings, [ReviewRating.good]);
    });

    testWidgets('a slip rates Again so the line comes back', (tester) async {
      final ratings = <ReviewRating>[];
      await tester.pumpWidget(
        _finished(hadLearnPhase: true, hadMistake: true, onRate: ratings.add),
      );
      await tester.pump();

      expect(
        find.text('Learned with mistakes — you will see it again.'),
        findsOneWidget,
      );
      expect(ratings, [ReviewRating.again]);
    });

    testWidgets('a reviewed line still asks for a rating', (tester) async {
      final ratings = <ReviewRating>[];
      await tester.pumpWidget(
        _finished(hadLearnPhase: false, hadMistake: true, onRate: ratings.add),
      );
      await tester.pump();

      expect(find.text('How well did you know this?'), findsOneWidget);
      expect(ratings, isEmpty);
    });
  });
}
