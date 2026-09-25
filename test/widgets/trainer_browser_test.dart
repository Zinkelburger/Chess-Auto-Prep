import 'package:chess_auto_prep/features/training/models/training_source_context.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'dart:async';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/design_system/components/list_search_field.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/widgets/training/trainer_browser.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/trainer_browser_session.dart';
import '../services/training/training_fakes.dart';
import 'package:chess_auto_prep/features/training/controllers/training_session_controller.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';

RepertoireLine _line(
  String id, {
  String? chapter,
  List<String>? moves,
  bool isModelGame = false,
}) => RepertoireLine(
  id: id,
  name: 'Line $id',
  moves: moves ?? const ['e4', 'e5'],
  color: 'white',
  startPosition: Chess.initial,
  fullPgn: '',
  chapter: chapter,
  isModelGame: isModelGame,
);

RepertoireReviewEntry _entry(String lineId, {DateTime? due}) =>
    RepertoireReviewEntry(
      repertoireId: 'rep.pgn',
      lineId: lineId,
      lineName: lineId,
      lastRating: 'good',
      dueDateUtc: due,
    );

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: ThemeData.dark(),
  home: Scaffold(body: SizedBox(width: 900, height: 700, child: child)),
);

class _DelayedReviews extends FakeReviewService {
  final gate = Completer<void>();
  int attempts = 0;
  @override
  Future<void> saveAll(
    List<RepertoireReviewEntry> entries, {
    required TrainingSourceContext source,
    String? repertoireId,
  }) async {
    attempts++;
    await gate.future;
    await super.saveAll(entries, repertoireId: repertoireId, source: source);
  }
}

Widget _liveBrowser(
  TrainingSessionController session, {
  void Function(RepertoireLine)? onPreviewLine,
}) => _wrap(
  ListenableBuilder(
    listenable: session,
    builder: (_, _) =>
        TrainerBrowser(session: session, onPreviewLine: onPreviewLine),
  ),
);

void main() {
  group('TrainerBrowser', () {
    testWidgets('chapters are the first list; tapping one opens it', (
      tester,
    ) async {
      final session = await trainerBrowserSession(
        lines: [
          _line('A', chapter: 'One'),
          _line('B', chapter: 'One'),
          _line('C', chapter: 'Two'),
        ],
        name: 'Colle',
        reviewMap: const {},
      );
      await tester.pumpWidget(_wrap(TrainerBrowser(session: session)));

      expect(find.text('2 chapters'), findsOneWidget);
      expect(find.text('One'), findsOneWidget);
      expect(find.text('Two'), findsOneWidget);
      // Lines stay behind their chapter — no wall of variations.
      expect(find.text('Line A'), findsNothing);

      await tester.tap(find.text('One'));
      expect(session.activeChapter, 'One');
    });

    testWidgets('an open chapter lists only its lines, with a way back', (
      tester,
    ) async {
      final session = await trainerBrowserSession(
        lines: [
          _line('A', chapter: 'One'),
          _line('B', chapter: 'One'),
          _line('C', chapter: 'Two'),
        ],
        name: 'Colle',
        activeChapter: 'One',
        reviewMap: const {},
      );
      await tester.pumpWidget(_wrap(TrainerBrowser(session: session)));

      expect(find.text('Line A'), findsOneWidget);
      expect(find.text('Line B'), findsOneWidget);
      expect(find.text('Line C'), findsNothing);

      await tester.tap(find.byTooltip('Back to all chapters'));
      expect(session.activeChapter, isNull);
    });

    testWidgets('Review is muted when nothing is due, Learn counts the '
        'untrained lines', (tester) async {
      final session = await trainerBrowserSession(
        lines: [_line('A'), _line('B')],
        name: 'Colle',
        reviewMap: const {},
      );
      await tester.pumpWidget(_wrap(TrainerBrowser(session: session)));

      expect(find.text('2 untrained'), findsOneWidget);
      expect(find.text('Nothing due'), findsOneWidget);

      // Tapping through the button's own subtitle keeps this off the
      // per-line action pills, which use the same two verbs.
      await tester.tap(find.text('Nothing due'));
      expect(
        session.currentLine,
        isNull,
        reason: 'muted Review must not start a run',
      );

      await tester.tap(find.text('2 untrained'));
      expect(session.currentLine?.id, 'A');
      expect(session.sessionIntent, TrainingIntent.learn);
    });

    testWidgets('the button says what the sitting covers, not the backlog', (
      tester,
    ) async {
      final session = await trainerBrowserSession(
        lines: [for (var i = 0; i < 30; i++) _line('L$i')],
        name: 'Colle',
        reviewMap: const {},
        settings: TrainingSettings(
          newLinesPerSession: 10,
          learnRequiresClick: true,
        ),
      );
      await tester.pumpWidget(_wrap(TrainerBrowser(session: session)));

      // "30 untrained" on a bought course reads as a threat; the button has
      // to promise the ten it will actually show.
      expect(find.text('10 lines'), findsOneWidget);
      expect(find.text('30 untrained'), findsNothing);
      // The progress strip still tells the truth about the whole scope.
      expect(find.text('0 learned · 0 due · 30 untrained'), findsOneWidget);
    });

    testWidgets('a model game is offered to read, never to drill', (
      tester,
    ) async {
      RepertoireLine? previewed;
      final session = await trainerBrowserSession(
        lines: [_line('A'), _line('M', isModelGame: true)],
        name: 'Colle',
        reviewMap: const {},
      );
      await tester.pumpWidget(
        _wrap(
          TrainerBrowser(
            session: session,
            onPreviewLine: (line) => previewed = line,
          ),
        ),
      );

      // Somebody else's whole game is not a line you are meant to reproduce,
      // so it is not part of the untrained count either.
      expect(find.text('1 untrained'), findsOneWidget);
      expect(find.text('Model game'), findsOneWidget);
      expect(find.text('Read'), findsOneWidget);

      await tester.tap(find.text('Line M'));
      expect(session.currentLine, isNull);
      expect(previewed?.id, 'M');
    });

    testWidgets('the browser focuses on practice, not configuration', (
      tester,
    ) async {
      final session = await trainerBrowserSession(
        lines: [_line('A')],
        name: 'Vigorito QGD',
        reviewMap: const {},
      );
      await tester.pumpWidget(_wrap(TrainerBrowser(session: session)));
      expect(find.text('White repertoire'), findsOneWidget);
      expect(find.text('Black Repertoire'), findsNothing);
      expect(find.text('Chapters…'), findsNothing);
      expect(find.byIcon(Icons.settings_outlined), findsNothing);
    });

    testWidgets('a due line enables Review and says when it fell due', (
      tester,
    ) async {
      final session = await trainerBrowserSession(
        lines: [_line('A')],
        name: 'Colle',
        reviewMap: {
          'A': _entry(
            'A',
            due: DateTime.now().toUtc().subtract(const Duration(days: 3)),
          ),
        },
      );
      await tester.pumpWidget(_wrap(TrainerBrowser(session: session)));

      expect(find.text('1 due now'), findsOneWidget);
      expect(find.text('Due 3d ago'), findsOneWidget);

      await tester.tap(find.text('1 due now'));
      expect(session.currentLine?.id, 'A');
      expect(session.sessionIntent, TrainingIntent.review);
    });

    testWidgets('untrained lines say "Untrained", never "New", and are '
        'trainable in one click', (tester) async {
      final session = await trainerBrowserSession(
        lines: [_line('A')],
        name: 'Colle',
        reviewMap: const {},
      );
      await tester.pumpWidget(_wrap(TrainerBrowser(session: session)));

      expect(find.text('Untrained'), findsOneWidget);
      expect(find.text('New'), findsNothing);
      // The row carries its own verb.
      expect(find.text('Learn'), findsWidgets);

      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.data == 'Line A',
        ),
      );
      expect(session.currentLine?.id, 'A');
    });

    testWidgets('lines outside every chapter get their own bucket', (
      tester,
    ) async {
      final session = await trainerBrowserSession(
        lines: [
          _line('A', chapter: 'One'),
          _line('B', chapter: 'One'),
          _line('Intro'),
        ],
        name: 'Colle',
        reviewMap: const {},
      );
      await tester.pumpWidget(_wrap(TrainerBrowser(session: session)));

      expect(find.text('Other lines'), findsOneWidget);
      await tester.tap(find.text('Other lines'));
      expect(session.activeChapter, TrainingSessionController.ungroupedChapter);
    });

    testWidgets('a chapter containing only model games remains readable', (
      tester,
    ) async {
      final session = await trainerBrowserSession(
        lines: [
          _line('A', chapter: 'Practice'),
          _line('M', chapter: 'Examples', isModelGame: true),
        ],
      );
      RepertoireLine? preview;
      await tester.pumpWidget(
        _liveBrowser(session, onPreviewLine: (line) => preview = line),
      );
      expect(session.chapters, ['Practice']);
      expect(find.text('Examples'), findsOneWidget);
      await tester.tap(find.text('Examples'));
      await tester.pump();
      expect(session.activeChapter, 'Examples');
      expect(find.text('Line M'), findsOneWidget);
      await tester.tap(find.text('Line M'));
      expect(preview?.id, 'M');
      expect(session.currentLine, isNull);
    });

    testWidgets(
      'linear browser advertises the whole sitting and starts its existing run',
      (tester) async {
        final session = await trainerBrowserSession(
          lines: [for (var i = 0; i < 30; i++) _line('L$i')],
          settings: TrainingSettings(
            newLinesPerSession: 10,
            learnRequiresClick: true,
          ),
        );
        session.setRepetitionMode(RepetitionMode.linear);
        await tester.pumpWidget(_liveBrowser(session));
        expect(find.text('30 untrained'), findsOneWidget);
        expect(find.text('10 lines'), findsNothing);
        await tester.tap(find.text('30 untrained'));
        expect(session.currentLine?.id, 'L0');
        expect(session.remainingInRun, 30);
      },
    );

    testWidgets(
      'filtered bulk selection preserves the captured whole chapter while saving',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final reviews = _DelayedReviews();
        final session = await trainerBrowserSession(
          lines: [
            _line('A', chapter: 'One'),
            _line('B', chapter: 'One'),
            _line('C', chapter: 'Two'),
          ],
          activeChapter: 'One',
          reviewMap: {'B': _entry('B'), 'C': _entry('C')},
          reviews: reviews,
        );
        await tester.pumpWidget(_liveBrowser(session));
        await tester.tap(find.text('Mark lines I know'));
        await tester.pump();
        await tester.enterText(
          find.descendant(
            of: find.byType(ListSearchField),
            matching: find.byType(TextField),
          ),
          'Line A',
        );
        await tester.pump();
        expect(find.text('Line B'), findsNothing);
        await tester.tap(
          find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == 'Line A',
          ),
        );
        await tester.pump();
        await tester.tap(find.text('Save'));
        await tester.pump();
        expect(reviews.attempts, 1);
        expect(
          tester
              .widget<FilledButton>(
                find.ancestor(
                  of: find.text('Save'),
                  matching: find.byType(FilledButton),
                ),
              )
              .onPressed,
          isNull,
        );
        reviews.gate.complete();
        await tester.pumpAndSettle();
        expect(find.text('Save'), findsNothing);
        expect(session.reviewMap['A']?.isNew, isFalse);
        expect(session.reviewMap['B']?.isNew, isFalse);
        expect(session.reviewMap['C']?.isNew, isFalse);
        expect(reviews.history.map((entry) => entry.lineId), ['A']);
      },
    );

    testWidgets(
      'a retained row command cannot start training after browser disposal',
      (tester) async {
        final session = await trainerBrowserSession(lines: [_line('A')]);
        await tester.pumpWidget(_liveBrowser(session));
        final tap = tester
            .widget<InkWell>(
              find
                  .ancestor(
                    of: find.text('Line A'),
                    matching: find.byType(InkWell),
                  )
                  .first,
            )
            .onTap!;
        await tester.pumpWidget(const SizedBox.shrink());
        tap();
        expect(session.currentLine, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
