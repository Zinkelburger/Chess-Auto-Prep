import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/widgets/training/trainer_browser.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _ungrouped = '__trainer_ungrouped__';

RepertoireLine _line(String id, {String? chapter, List<String>? moves}) =>
    RepertoireLine(
      id: id,
      name: 'Line $id',
      moves: moves ?? const ['e4', 'e5'],
      color: 'white',
      startPosition: Chess.initial,
      fullPgn: '',
      chapter: chapter,
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
  theme: ThemeData.dark(),
  home: Scaffold(body: SizedBox(width: 900, height: 700, child: child)),
);

void main() {
  group('TrainerBrowser', () {
    testWidgets('chapters are the first list; tapping one opens it', (
      tester,
    ) async {
      String? opened;
      await tester.pumpWidget(
        _wrap(
          TrainerBrowser(
            title: 'Colle',
            lines: [
              _line('A', chapter: 'One'),
              _line('B', chapter: 'One'),
              _line('C', chapter: 'Two'),
            ],
            reviewMap: const {},
            chapterOf: (line) => line.chapter,
            onChapterSelected: (chapter) => opened = chapter,
            ungroupedChapter: _ungrouped,
            onTrainLine: (_) {},
          ),
        ),
      );

      expect(find.text('2 chapters'), findsOneWidget);
      expect(find.text('One'), findsOneWidget);
      expect(find.text('Two'), findsOneWidget);
      // Lines stay behind their chapter — no wall of variations.
      expect(find.text('Line A'), findsNothing);

      await tester.tap(find.text('One'));
      expect(opened, 'One');
    });

    testWidgets('an open chapter lists only its lines, with a way back', (
      tester,
    ) async {
      String? selected = 'One';
      await tester.pumpWidget(
        _wrap(
          TrainerBrowser(
            title: 'Colle',
            lines: [
              _line('A', chapter: 'One'),
              _line('B', chapter: 'One'),
              _line('C', chapter: 'Two'),
            ],
            reviewMap: const {},
            chapterOf: (line) => line.chapter,
            activeChapter: 'One',
            onChapterSelected: (chapter) => selected = chapter,
            ungroupedChapter: _ungrouped,
            onTrainLine: (_) {},
          ),
        ),
      );

      expect(find.text('Line A'), findsOneWidget);
      expect(find.text('Line B'), findsOneWidget);
      expect(find.text('Line C'), findsNothing);

      await tester.tap(find.byTooltip('Back to all chapters'));
      expect(selected, isNull);
    });

    testWidgets('Review is muted when nothing is due, Learn counts the '
        'untrained lines', (tester) async {
      var learned = 0;
      var reviewed = 0;
      await tester.pumpWidget(
        _wrap(
          TrainerBrowser(
            title: 'Colle',
            lines: [_line('A'), _line('B')],
            reviewMap: const {},
            ungroupedChapter: _ungrouped,
            onLearn: () => learned++,
            onReview: () => reviewed++,
            onTrainLine: (_) {},
          ),
        ),
      );

      expect(find.text('2 untrained'), findsOneWidget);
      expect(find.text('Nothing due'), findsOneWidget);

      // Tapping through the button's own subtitle keeps this off the
      // per-line action pills, which use the same two verbs.
      await tester.tap(find.text('Nothing due'));
      expect(reviewed, 0, reason: 'muted Review must not start a run');

      await tester.tap(find.text('2 untrained'));
      expect(learned, 1);
    });

    testWidgets('a due line enables Review and says when it fell due', (
      tester,
    ) async {
      var reviewed = 0;
      await tester.pumpWidget(
        _wrap(
          TrainerBrowser(
            title: 'Colle',
            lines: [_line('A')],
            reviewMap: {
              'A': _entry(
                'A',
                due: DateTime.now().toUtc().subtract(const Duration(days: 3)),
              ),
            },
            ungroupedChapter: _ungrouped,
            onLearn: () {},
            onReview: () => reviewed++,
            onTrainLine: (_) {},
          ),
        ),
      );

      expect(find.text('1 due now'), findsOneWidget);
      expect(find.text('Due 3d ago'), findsOneWidget);

      await tester.tap(find.text('1 due now'));
      expect(reviewed, 1);
    });

    testWidgets('untrained lines say "Untrained", never "New", and are '
        'trainable in one click', (tester) async {
      String? trained;
      await tester.pumpWidget(
        _wrap(
          TrainerBrowser(
            title: 'Colle',
            lines: [_line('A')],
            reviewMap: const {},
            ungroupedChapter: _ungrouped,
            onTrainLine: (line) => trained = line.id,
          ),
        ),
      );

      expect(find.text('Untrained'), findsOneWidget);
      expect(find.text('New'), findsNothing);
      // The row carries its own verb.
      expect(find.text('Learn'), findsWidgets);

      await tester.tap(find.text('Line A'));
      expect(trained, 'A');
    });

    testWidgets('lines outside every chapter get their own bucket', (
      tester,
    ) async {
      String? opened;
      await tester.pumpWidget(
        _wrap(
          TrainerBrowser(
            title: 'Colle',
            lines: [
              _line('A', chapter: 'One'),
              _line('B', chapter: 'One'),
              _line('Intro'),
            ],
            reviewMap: const {},
            chapterOf: (line) => line.chapter,
            onChapterSelected: (chapter) => opened = chapter,
            ungroupedChapter: _ungrouped,
            onTrainLine: (_) {},
          ),
        ),
      );

      expect(find.text('Other lines'), findsOneWidget);
      await tester.tap(find.text('Other lines'));
      expect(opened, _ungrouped);
    });
  });
}
