import 'package:chess_auto_prep/v2/ui/pane_tabs.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
    testWidgets('is left out while one tab is open', (tester) async {
      final tabs = await pumpStrip(tester);
      expect(find.text('Moves'), findsNothing);
      tabs.show('replies');
      await tester.pumpAndSettle();
      expect(find.text('Moves'), findsOneWidget);
      expect(find.text('Replies'), findsOneWidget);
    });

    testWidgets('the tabs share the width, whatever their words', (
      tester,
    ) async {
      await pumpStrip(tester, open: ['replies', 'explorer']);
      Size sizeOf(String label) => tester.getSize(
        find
            .ancestor(of: find.text(label), matching: find.byType(InkWell))
            .first,
      );
      expect(sizeOf('Moves').width, sizeOf('Explorer').width);
      expect(sizeOf('Moves').height, greaterThanOrEqualTo(paneTabHeight - 8));
      await expectSameWidthUnderPointer(tester, 'Replies');
    });
  });

  group('PaneTabStrip closing', () {
    testWidgets('a click brings a tab up, with no × on any', (tester) async {
      final tabs = await pumpStrip(tester, open: ['replies', 'explorer']);
      await tester.tap(find.text('Explorer'));
      await tester.pumpAndSettle();
      expect(tabs.selected, 'explorer');
      expect(find.byIcon(Icons.close), findsNothing);
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
