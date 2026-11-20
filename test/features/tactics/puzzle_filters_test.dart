import 'package:chess_auto_prep/chess/tactics/puzzle.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle_queue.dart';
import 'package:chess_auto_prep/features/tactics/puzzle_filters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The filter controls under the Tactics count: each change is kept at
/// once, and the day count is taken only when it is a whole number of days.
void main() {
  late List<PuzzleFilter> kept;

  /// The filters over [start], keeping each change as the set would.
  Future<void> pumpFilters(WidgetTester tester, PuzzleFilter start) async {
    kept = [];
    var filter = start;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                PuzzleFilters(
                  filter: filter,
                  onChanged: (next) => setState(() {
                    kept.add(next);
                    filter = next;
                  }),
                ),
                // Somewhere else to click, which takes focus from the box.
                const TextField(key: ValueKey('elsewhere')),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Finder daysBox() => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.focusNode != null,
  );

  Checkbox daysCheck(WidgetTester tester) => tester.widget<Checkbox>(
    find.descendant(
      of: find.byTooltip('Counted from the date the game was played.'),
      matching: find.byType(Checkbox),
    ),
  );

  testWidgets('a kind chip adds or takes out that kind of mistake', (
    tester,
  ) async {
    await pumpFilters(tester, const PuzzleFilter());
    await tester.tap(find.text('Inaccuracies ?!'));
    await tester.pump();
    expect(kept.last.kinds, contains(MistakeKind.inaccuracy));
    await tester.tap(find.text('Blunders ??'));
    await tester.pump();
    expect(kept.last.kinds, {
      MistakeKind.mistake,
      MistakeKind.inaccuracy,
      MistakeKind.custom,
    });
    expect(find.text('Custom'), findsOneWidget);
  });

  testWidgets('the order chips and the three ticks each change one thing', (
    tester,
  ) async {
    await pumpFilters(tester, const PuzzleFilter());
    bool chosen(String label) => tester
        .widget<FilterChip>(find.widgetWithText(FilterChip, label))
        .selected;
    expect(chosen('Newest first'), isTrue);
    expect(chosen('Worst success rate'), isFalse);
    await tester.tap(find.text('Worst success rate'));
    await tester.pump();
    expect(kept.last.order, PuzzleOrder.worstSuccess);
    expect(chosen('Newest first'), isFalse);
    expect(chosen('Worst success rate'), isTrue);
    await tester.tap(find.text('Group by game'));
    await tester.pump();
    expect(kept.last.groupByGame, isFalse);
    await tester.tap(find.text('Unreviewed only'));
    await tester.pump();
    expect(kept.last.unreviewedOnly, isTrue);
    await tester.tap(find.text('Hide one-star'));
    await tester.pump();
    expect(kept.last.hideOneStar, isFalse);
    expect(kept.last.order, PuzzleOrder.worstSuccess, reason: 'kept');
    expect(kept.last.groupByGame, isFalse, reason: 'kept');
  });

  testWidgets('every date by default; ticking Last limits to the number in '
      'the box, and unticking lets every date through again', (tester) async {
    await pumpFilters(tester, const PuzzleFilter());
    expect(daysCheck(tester).value, isFalse);
    expect(tester.widget<TextField>(daysBox()).enabled, isFalse);
    expect(find.text('14'), findsOneWidget);
    daysCheck(tester).onChanged!(true);
    await tester.pump();
    expect(kept.last.days, 14);
    expect(tester.widget<TextField>(daysBox()).enabled, isTrue);
    daysCheck(tester).onChanged!(false);
    await tester.pump();
    expect(kept.last.days, isNull);
  });

  testWidgets('a number typed in is taken on Enter and when the box is '
      'left; nothing, zero or the same number changes nothing', (tester) async {
    await pumpFilters(tester, const PuzzleFilter(days: 7));
    expect(find.text('7'), findsOneWidget);

    Future<void> submit(String text) async {
      await tester.enterText(daysBox(), text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }

    await submit('30');
    expect(kept.map((f) => f.days).toSet(), {30});

    for (final refused in ['0', '']) {
      final before = kept.length;
      await submit(refused);
      expect(kept, hasLength(before), reason: 'no filter of "$refused" days');
      expect(find.text('30'), findsOneWidget, reason: 'the box goes back');
    }

    final before = kept.length;
    await submit('30');
    expect(kept, hasLength(before), reason: 'the same number is no change');

    await submit('1');
    expect(kept.last.days, 1, reason: 'today alone is a window');

    await tester.enterText(daysBox(), '5');
    await tester.tap(find.byKey(const ValueKey('elsewhere')));
    await tester.pump();
    expect(kept.last.days, 5, reason: 'leaving the box takes it');
  });

  testWidgets('unticking Last while a number is being typed lets every date '
      'through: the box giving up focus does not take the number', (
    tester,
  ) async {
    await pumpFilters(tester, const PuzzleFilter(days: 7));
    await tester.enterText(daysBox(), '9');
    daysCheck(tester).onChanged!(false);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('elsewhere')));
    await tester.pump();
    expect(kept.map((f) => f.days), [null]);
  });

  testWidgets('ticked again after the box was emptied, Last is the '
      'fortnight it starts with', (tester) async {
    await pumpFilters(tester, const PuzzleFilter(days: 7));
    await tester.enterText(daysBox(), '');
    daysCheck(tester).onChanged!(false);
    await tester.pump();
    daysCheck(tester).onChanged!(true);
    await tester.pump();
    expect(kept.map((f) => f.days), [null, 14]);
  });

  testWidgets('the box follows a filter changed elsewhere and keeps the '
      'last count while every date shows', (tester) async {
    var filter = const PuzzleFilter(days: 7);
    late StateSetter rebuild;
    final changes = <PuzzleFilter>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Column(
                children: [
                  PuzzleFilters(filter: filter, onChanged: changes.add),
                  const TextField(key: ValueKey('elsewhere')),
                ],
              );
            },
          ),
        ),
      ),
    );
    rebuild(() => filter = const PuzzleFilter(days: 21));
    await tester.pump();
    expect(find.text('21'), findsOneWidget);

    // Every date: the box keeps the last count, ready for the tick.
    rebuild(() => filter = const PuzzleFilter());
    await tester.pump();
    expect(find.text('21'), findsOneWidget);
    tester
        .widget<Checkbox>(
          find.descendant(
            of: find.byTooltip('Counted from the date the game was played.'),
            matching: find.byType(Checkbox),
          ),
        )
        .onChanged!(true);
    expect(changes.single.days, 21);
  });
}
