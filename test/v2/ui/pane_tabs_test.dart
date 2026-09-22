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
  group('PaneTabs', () {
    test('starts with the pinned tab and whatever else was asked open', () {
      final tabs = PaneTabs(all, open: ['graph', 'replies', 'nonsense']);
      expect(tabs.open, ['moves', 'graph', 'replies']);
      expect(tabs.selected, 'moves');
      expect(tabs.closed, [explorer]);
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

    test('openInBackground opens without bringing up', () {
      final tabs = PaneTabs(all)..openInBackground('graph');
      expect(tabs.open, ['moves', 'graph']);
      expect(tabs.selected, 'moves');
    });

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

  group('PaneTabStrip', () {
    late PaneTabs tabs;

    Future<void> pump(WidgetTester tester, {Widget? trailing}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: Scaffold(
            body: Column(
              children: [
                PaneTabStrip(
                  tabs: tabs,
                  trailing: trailing,
                  closeShortcut: 'Ctrl+W',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    tearDown(() => tabs.dispose());

    testWidgets('is left out while one tab is open', (tester) async {
      tabs = PaneTabs(all);
      await pump(tester);
      expect(find.text('Moves'), findsNothing);
      tabs.show('replies');
      await tester.pumpAndSettle();
      expect(find.text('Moves'), findsOneWidget);
      expect(find.text('Replies'), findsOneWidget);
    });

    testWidgets('a click brings a tab up; its × and Ctrl+W close it', (
      tester,
    ) async {
      tabs = PaneTabs(all, open: ['replies', 'explorer']);
      await pump(tester);
      await tester.tap(find.text('Explorer'));
      await tester.pumpAndSettle();
      expect(tabs.selected, 'explorer');
      expect(find.byTooltip('Close Explorer (Ctrl+W)'), findsOneWidget);
      // The pinned tab has no ×; a tab that is not up does not draw its
      // × but holds the room for it, so nothing shifts under the pointer.
      expect(find.byTooltip('Close Moves'), findsNothing);
      expect(find.byTooltip('Close Replies'), findsOneWidget);
      final repliesTab = find
          .ancestor(of: find.text('Replies'), matching: find.byType(InkWell))
          .first;
      final away = tester.getSize(repliesTab).width;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      await mouse.moveTo(tester.getCenter(find.text('Replies')));
      await tester.pumpAndSettle();
      expect(tester.getSize(repliesTab).width, away);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close Explorer (Ctrl+W)'));
      await tester.pumpAndSettle();
      expect(tabs.open, ['moves', 'replies']);
      expect(tabs.selected, 'replies');
    });

    testWidgets('a middle click closes a tab', (tester) async {
      tabs = PaneTabs(all, open: ['replies']);
      await pump(tester);
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await gesture.down(tester.getCenter(find.text('Replies')));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tabs.open, ['moves']);
    });

    testWidgets('a tab dragged onto another goes in front of it', (
      tester,
    ) async {
      tabs = PaneTabs(all, open: ['replies', 'explorer', 'graph']);
      await pump(tester);
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

    testWidgets('the trailing control sits at the right edge', (tester) async {
      tabs = PaneTabs(all, open: ['replies']);
      await pump(tester, trailing: const Text('Next gap'));
      expect(
        tester.getTopRight(find.text('Next gap')).dx,
        greaterThan(tester.getTopRight(find.text('Replies')).dx),
      );
    });
  });
}
