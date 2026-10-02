import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/chess/training/training_options.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/trainer/train_pane.dart';
import 'package:chess_auto_prep/features/trainer/trainer.dart';
import 'package:chess_auto_prep/features/trainer/training_scope.dart';
import 'package:chess_auto_prep/storage/settings.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/move_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/books_fixture.dart';
import '../../support/scripted_files.dart';
import '../../support/scripted_progress.dart';
import '../../support/session_fixture.dart';

const _chapter = '''
// Color: White

[Event "Italian"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 {The Italian.} *
''';

void main() {
  // Half the card's height at the default window, as a tool opened under
  // the lesson leaves it, and a narrower pane whose buttons wrap; on the
  // desktop, whose buttons are the compact ones the app shows. The test
  // font's square glyphs are about half again as wide as the app's, so the
  // widths here stand for narrower panes in the app.
  for (final size in [const Size(640, 240), const Size(420, 320)]) {
    testWidgets(
      'a lesson in a ${size.width.round()}×${size.height.round()} pane keeps '
      'its prompt, control and way out in view',
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
      (tester) async {
        final fixture = await openSession(_chapter);
        final files = ScriptedProgress();
        final moves = MoveEntry();
        final analysis = EngineAnalysis(
          fixture.session,
          () async => const StartFailed('no engine in this test'),
        );
        final settings = SettingsStore(
          initial: Settings(training: TrainingOptions(rateReviews: true)),
        );
        final italian = (
          source: fixture.ref.path,
          id: 'line_ZTQgZTUgTmYzIE5jNiBCYz',
        );
        files.reviews[italian] = Review(
          key: italian,
          lineName: 'Italian',
          intervalDays: 4,
          lastRating: 'good',
          due: DateTime.now().subtract(const Duration(hours: 1)),
        );
        final trainer = Trainer(
          session: fixture.session,
          settings: settings,
          chapters: ScopeReader(
            files: ScriptedFiles(),
            documents: fixture.store,
          ),
          files: files,
          analysis: analysis,
          time: (now: DateTime.now, jitter: () => 0),
          books: booksWith(),
        );
        addTearDown(() {
          trainer.dispose();
          settings.dispose();
          moves.dispose();
          analysis.dispose();
          fixture.dispose();
        });
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: darkTheme(),
            home: Scaffold(
              body: TrainPane(trainer: trainer, moves: moves, onRead: (_) {}),
            ),
          ),
        );
        await tester.pumpAndSettle();
        trainer.review();
        await tester.pumpAndSettle();

        final pane = Offset.zero & size;
        void inView(Finder finder) {
          expect(finder, findsOneWidget);
          final rect = tester.getRect(finder);
          expect(
            pane.contains(rect.topLeft) && pane.contains(rect.bottomRight),
            isTrue,
            reason: '$finder at $rect is outside the $size pane',
          );
        }

        inView(find.text('Your move'));
        inView(find.text('Back to lines'));
        for (final uci in ['e2e4', 'g1f3', 'f1c4']) {
          trainer.lesson!.play(uci);
          await tester.pump(const Duration(seconds: 2));
          await tester.pumpAndSettle();
        }
        inView(find.text('Line complete!'));
        inView(find.widgetWithText(FilledButton, 'Good · 10d'));
        inView(find.widgetWithText(OutlinedButton, 'Again · now'));
        inView(find.text('Back to lines'));
        expect(
          find.text('How well did you know this?'),
          findsNothing,
          reason: 'a short pane rates without the question',
        );
        // Too short for its wrapped buttons, the narrow pane scrolls whole.
        await tester.ensureVisible(find.byTooltip('Line actions'));
        await tester.tap(find.byTooltip('Line actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('View moves and notes'));
        await tester.pumpAndSettle();
        expect(find.text('Hide'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
