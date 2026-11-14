import 'package:chess_auto_prep/ui/pane_tabs.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const moves = PaneTab('moves', 'Moves', pinned: true);
const replies = PaneTab('replies', 'Replies');
const explorer = PaneTab('explorer', 'Explorer');
const graph = PaneTab('graph', 'Graph');
const all = [moves, replies, explorer, graph];

void main() {
  group('PaneTabs opening and closing', () {
    test('starts with the pinned tab and whatever else was asked open', () {
      final tabs = PaneTabs(all, open: ['graph', 'replies', 'nonsense']);
      expect(tabs.open, ['moves', 'graph', 'replies']);
      expect(tabs.selected, 'moves');
      expect(tabs.isOpen('explorer'), isFalse);
    });

    test('show opens at the right end and brings up; close goes left', () {
      final tabs = PaneTabs(all);
      var told = 0;
      tabs.addListener(() => told++);
      tabs.show('explorer');
      tabs.show('replies');
      expect(tabs.open, ['moves', 'explorer', 'replies']);
      expect(tabs.selected, 'replies');
      expect(told, 2);
      tabs.show('replies');
      expect(told, 2, reason: 'nothing changed');
      tabs.close('replies');
      expect(tabs.open, ['moves', 'explorer']);
      expect(tabs.selected, 'explorer', reason: 'the left neighbour');
      tabs.close('moves');
      expect(tabs.open, ['moves', 'explorer'], reason: 'pinned stays');
      tabs.closeCurrent();
      expect(tabs.open, ['moves']);
      expect(tabs.selected, 'moves');
    });

    test('closing a tab that is not up leaves the current one up', () {
      final tabs = PaneTabs(all, open: ['replies', 'explorer'])
        ..show('explorer')
        ..close('replies');
      expect(tabs.selected, 'explorer');
      expect(tabs.open, ['moves', 'explorer']);
    });
  });

  group('PaneTabs order', () {
    test('next and previous wrap round the open tabs', () {
      final tabs = PaneTabs(all, open: ['replies', 'graph']);
      tabs.next();
      expect(tabs.selected, 'replies');
      tabs.next();
      tabs.next();
      expect(tabs.selected, 'moves');
      tabs.previous();
      expect(tabs.selected, 'graph');
      final alone = PaneTabs(all);
      var told = 0;
      alone.addListener(() => told++);
      alone.next();
      expect(told, 0, reason: 'one tab: nowhere to go');
    });

    test('move puts a tab in front of another, never in front of the '
        'pinned one', () {
      final tabs = PaneTabs(all, open: ['replies', 'explorer', 'graph']);
      tabs.move('graph', before: 'replies');
      expect(tabs.open, ['moves', 'graph', 'replies', 'explorer']);
      tabs.move('explorer', before: 'moves');
      expect(tabs.open, ['moves', 'graph', 'replies', 'explorer']);
      tabs.move('moves', before: 'graph');
      expect(tabs.open, ['moves', 'graph', 'replies', 'explorer']);
    });
  });

  group('PaneTabStrip layout', () {
    testWidgets('keeps navigation visible while one tab is open', (
      tester,
    ) async {
      final tabs = await pumpStrip(tester);
      expect(find.text('Moves'), findsOneWidget);
      tabs.show('replies');
      await tester.pumpAndSettle();
      expect(find.text('Moves'), findsOneWidget);
      expect(find.text('Replies'), findsOneWidget);
    });

    testWidgets('tabs stay compact instead of stretching across the pane', (
      tester,
    ) async {
      await pumpStrip(tester, open: ['replies', 'explorer']);
      Size sizeOf(String label) => tester.getSize(
        find
            .ancestor(of: find.text(label), matching: find.byType(InkWell))
            .first,
      );
      expect(sizeOf('Moves').width, lessThan(sizeOf('Explorer').width));
      expect(sizeOf('Explorer').width, lessThan(150));
      expect(sizeOf('Moves').height, greaterThanOrEqualTo(paneTabHeight - 8));
      await expectSameWidthUnderPointer(tester, 'Replies');
    });
  });

  group('PaneTabStrip closing', () {
    testWidgets('a click selects and a visible close button closes the tab', (
      tester,
    ) async {
      final tabs = await pumpStrip(tester, open: ['replies', 'explorer']);
      await tester.tap(find.text('Explorer'));
      await tester.pumpAndSettle();
      expect(tabs.selected, 'explorer');
      expect(find.byIcon(Icons.close), findsNWidgets(2));
      await tester.tap(find.byTooltip('Close Explorer'));
      await tester.pumpAndSettle();
      expect(tabs.open, ['moves', 'replies']);
      expect(tabs.selected, 'replies');
    });

    testWidgets('a middle click closes a tab', (tester) async {
      final tabs = await pumpStrip(tester, open: ['replies']);
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await gesture.down(tester.getCenter(find.text('Replies')));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tabs.open, ['moves']);
    });
  });

  group('PaneTabStrip dragging', () {
    testWidgets('a tab dragged onto another goes in front of it', (
      tester,
    ) async {
      final tabs = await pumpStrip(
        tester,
        open: ['replies', 'explorer', 'graph'],
      );
      final from = tester.getCenter(find.text('Graph'));
      final to = tester.getCenter(find.text('Replies'));
      final gesture = await tester.startGesture(from);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tabs.open, ['moves', 'graph', 'replies', 'explorer']);
    });
  });

  test('a tab is the same tab whatever it is called', () {
    expect(const PaneTab('a', 'A'), const PaneTab('a', 'Other'));
    expect(const PaneTab('a', 'A'), isNot(const PaneTab('b', 'A')));
  });

  test('of tabs none of which is pinned, the last open one stays', () {
    final tabs = PaneTabs(
      const [replies, explorer],
      open: ['replies', 'explorer'],
    );
    addTearDown(tabs.dispose);
    tabs.close('replies');
    expect(tabs.open, ['explorer']);
    tabs.close('explorer');
    expect(tabs.open, ['explorer']);
  });

  group('PaneTabStrip around its tabs', () {
    Future<void> strip(
      WidgetTester tester,
      PaneTabs<String> tabs, {
      double width = 600,
      VoidCallback? onAdd,
      void Function(String, Offset)? onContextMenu,
    }) async {
      addTearDown(tabs.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  width: width,
                  child: PaneTabStrip(
                    tabs: tabs,
                    onAdd: onAdd,
                    onContextMenu: onContextMenu,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final many = [
      moves,
      for (var i = 1; i <= 8; i++) PaneTab('t$i', 'Tab number $i'),
    ];
    ScrollPosition scroll(WidgetTester tester) =>
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;

    testWidgets('a tab that comes up out of view is scrolled to', (
      tester,
    ) async {
      final tabs = PaneTabs(many, open: [for (var i = 1; i <= 8; i++) 't$i']);
      await strip(tester, tabs, width: 200);
      expect(scroll(tester).pixels, 0);
      tabs.show('t8');
      await tester.pumpAndSettle();
      expect(scroll(tester).pixels, greaterThan(0));
    });

    testWidgets('the wheel scrolls the row, either way it turns', (
      tester,
    ) async {
      final tabs = PaneTabs(many, open: [for (var i = 1; i <= 8; i++) 't$i']);
      await strip(tester, tabs, width: 200);
      final at = tester.getCenter(find.text('Moves'));
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          scrollDelta: Offset(0, 40),
        ).copyWith(position: at),
      );
      await tester.pump();
      expect(scroll(tester).pixels, 40);
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          scrollDelta: Offset(30, 0),
        ).copyWith(position: at),
      );
      await tester.pump();
      expect(scroll(tester).pixels, 70);
      // A trackpad's smallest step counts too.
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          scrollDelta: Offset(0, 1),
        ).copyWith(position: at),
      );
      await tester.pump();
      expect(scroll(tester).pixels, 71);
    });

    testWidgets('a new board can be asked for with every tab open, and the '
        'menu offers only the closed ones', (tester) async {
      var added = 0;
      await strip(
        tester,
        PaneTabs(all, open: ['replies', 'explorer', 'graph']),
        onAdd: () => added++,
      );
      await tester.tap(find.byTooltip('New analysis board'));
      expect(added, 1);
      await strip(tester, PaneTabs(all, open: ['replies']));
      await tester.tap(find.byTooltip('Open tab'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(MenuItemButton, 'Explorer'), findsOneWidget);
      expect(find.widgetWithText(MenuItemButton, 'Replies'), findsNothing);
    });

    testWidgets('the menu key on a focused tab opens its menu, and does '
        'nothing where there is none', (tester) async {
      final asked = <String>[];
      await strip(
        tester,
        PaneTabs(all, open: ['replies']),
        onContextMenu: (id, _) => asked.add(id),
      );
      Focus.of(tester.element(find.text('Replies'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      expect(asked, ['replies']);
      await strip(tester, PaneTabs(all, open: ['replies']));
      Focus.of(tester.element(find.text('Replies'))).requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tab alone, with nobody to ask, has no close button', (
      tester,
    ) async {
      await strip(tester, PaneTabs(const [replies, explorer]));
      expect(find.byTooltip('Close Replies'), findsNothing);
      await strip(
        tester,
        PaneTabs(const [replies, explorer], open: ['replies', 'explorer']),
      );
      expect(find.byTooltip('Close Replies'), findsOneWidget);
    });
  });
}

/// A strip over tabs with [open] open, disposed when the test ends.
Future<PaneTabs<String>> pumpStrip(
  WidgetTester tester, {
  List<String> open = const [],
}) async {
  final tabs = PaneTabs(all, open: open);
  addTearDown(tabs.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: darkTheme(),
      home: Scaffold(
        body: Column(children: [PaneTabStrip(tabs: tabs)]),
      ),
    ),
  );
  await tester.pump();
  return tabs;
}

/// Hovering the tab labelled [label] leaves its width as it was.
Future<void> expectSameWidthUnderPointer(
  WidgetTester tester,
  String label,
) async {
  final tab = find
      .ancestor(of: find.text(label), matching: find.byType(InkWell))
      .first;
  final away = tester.getSize(tab).width;
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer();
  await mouse.moveTo(tester.getCenter(find.text(label)));
  await tester.pumpAndSettle();
  expect(tester.getSize(tab).width, away);
  await mouse.removePointer();
  await tester.pumpAndSettle();
}
