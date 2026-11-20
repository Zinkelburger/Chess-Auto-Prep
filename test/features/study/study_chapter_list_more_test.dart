// The chapter list of an open study: which row is the board's, what a
// row's menu offers, when rows can be dragged, and how the list keeps the
// board's chapter in view.

import 'package:chess_auto_prep/chess/pgn/study.dart';
import 'package:chess_auto_prep/features/study/study_chapter_list.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<StudyChapter> _chapters(int count) => [
  for (var i = 0; i < count; i++)
    StudyChapter(
      index: i,
      name: 'Chapter $i',
      orientation: i.isEven ? Side.white : Side.black,
    ),
];

void main() {
  late List<String> asked;

  setUp(() => asked = []);

  /// [height] is the whole list's, search field included.
  Future<void> pump(
    WidgetTester tester, {
    List<StudyChapter>? chapters,
    int? active = 0,
    bool busy = false,
    double height = 400,
  }) async {
    ChapterActions actionsFor(StudyChapter chapter) {
      void say(String what) => asked.add('$what ${chapter.index}');
      return (
        rename: () => say('rename'),
        tags: () => say('tags'),
        root: () => say('root'),
        clearAnnotations: () => say('clearAnnotations'),
        clearVariations: () => say('clearVariations'),
        face: (side) => say('face ${side.name}'),
        move: (by) => say('move $by'),
        copyPgn: () => say('copyPgn'),
        remove: () => say('remove'),
        moveTo: () => say('moveTo'),
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: height,
              child: StudyChapterList(
                chapters: chapters ?? _chapters(60),
                active: active,
                busy: busy,
                onOpen: (index) => asked.add('open $index'),
                actionsFor: actionsFor,
                onReorder: (from, to) => asked.add('reorder $from $to'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> rowAction(WidgetTester tester, int row, String label) async {
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Chapter $row'),
          matching: find.byType(ChapterRow),
        ),
        matching: find.byTooltip('Chapter actions'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  ScrollPosition position(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).last).position;

  Finder selectedRow() => find.byWidgetPredicate(
    (widget) => widget is Semantics && (widget.properties.selected ?? false),
  );

  testWidgets('the board\'s chapter is the selected row', (tester) async {
    await pump(tester, chapters: _chapters(3), active: 1);
    expect(
      find.descendant(of: selectedRow(), matching: find.text('Chapter 1')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: selectedRow(), matching: find.text('Chapter 0')),
      findsNothing,
    );
  });

  testWidgets('a chapter facing White offers only Face Black', (
    tester,
  ) async {
    await pump(tester, chapters: _chapters(3));
    await rowAction(tester, 0, 'Face White');
    expect(asked, isEmpty);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    await rowAction(tester, 0, 'Face Black');
    expect(asked, ['face black 0']);
  });

  testWidgets('a chapter facing Black offers only Face White', (
    tester,
  ) async {
    await pump(tester, chapters: _chapters(3));
    await rowAction(tester, 1, 'Face Black');
    expect(asked, isEmpty);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    await rowAction(tester, 1, 'Face White');
    expect(asked, ['face white 1']);
  });

  testWidgets('Move up and Move down move the chapter one place', (
    tester,
  ) async {
    await pump(tester, chapters: _chapters(3));
    await rowAction(tester, 1, 'Move up');
    await rowAction(tester, 1, 'Move down');
    expect(asked, ['move -1 1', 'move 1 1']);
  });

  testWidgets('rows can be dragged only while the whole list shows and '
      'nothing is being written', (tester) async {
    await pump(tester, chapters: _chapters(3));
    expect(find.byTooltip('Drag to reorder'), findsNWidgets(3));

    await tester.enterText(find.byType(TextField), 'chapter 1');
    await tester.pumpAndSettle();
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.byTooltip('Drag to reorder'), findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await pump(tester, chapters: _chapters(3), busy: true);
    expect(find.byTooltip('Drag to reorder'), findsNothing);
  });

  testWidgets('a list with no chapters says so', (tester) async {
    await pump(tester, chapters: const [], active: null);
    expect(find.text('No chapters yet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('keeping the board\'s chapter in view', () {
    /// The list's height that leaves [rows] rows of room under the
    /// search field.
    Future<double> heightFor(WidgetTester tester, double rows) async {
      await pump(tester, active: null);
      final room = position(tester).viewportDimension;
      return 400 - room + rows * listRowHeight;
    }

    testWidgets('a chapter already in view does not move the list', (
      tester,
    ) async {
      await pump(tester, active: 3);
      expect(position(tester).pixels, 0);
    });

    testWidgets('the board moving to a chapter out of view scrolls to it', (
      tester,
    ) async {
      await pump(tester, active: 0);
      expect(position(tester).pixels, 0);
      await pump(tester, active: 30);
      expect(position(tester).pixels, 30 * listRowHeight);
      expect(find.text('Chapter 30'), findsOneWidget);
    });

    testWidgets('the last row that fits whole is in view already', (
      tester,
    ) async {
      final height = await heightFor(tester, 10);
      await pump(tester, active: 9, height: height);
      expect(position(tester).pixels, 0);
    });

    testWidgets('a row cut off at the bottom is scrolled whole into view', (
      tester,
    ) async {
      final height = await heightFor(tester, 10.5);
      await pump(tester, active: 10, height: height);
      expect(position(tester).pixels, greaterThan(0));
      final list = tester.getRect(find.byType(Scrollable).last);
      final row = tester.getRect(
        find.ancestor(
          of: find.text('Chapter 10'),
          matching: find.byType(ChapterRow),
        ),
      );
      expect(row.bottom, lessThanOrEqualTo(list.bottom));
    });

    testWidgets('clearing a search brings the board\'s chapter back into '
        'view', (tester) async {
      await pump(tester, active: 30);
      final shown = position(tester).pixels;
      expect(shown, greaterThan(0));
      await tester.enterText(find.byType(TextField), 'chapter');
      await tester.pumpAndSettle();
      position(tester).jumpTo(0);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(position(tester).pixels, shown);
    });

    testWidgets('the board moving while a search shows leaves the found '
        'rows where they are', (tester) async {
      await pump(tester, active: 0);
      await tester.enterText(find.byType(TextField), 'chapter');
      await tester.pumpAndSettle();
      await pump(tester, active: 30);
      expect(position(tester).pixels, 0);
    });
  });
}
