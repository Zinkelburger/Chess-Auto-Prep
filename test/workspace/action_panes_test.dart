import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/action_layout.dart';
import 'package:chess_auto_prep/workspace/action_panes.dart';
import 'package:chess_auto_prep/workspace/workspace_tabs.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_explorer.dart';
import '../support/session_fixture.dart';

Future<ActionLayout> pumpPanes(WidgetTester tester) async {
  final fixture = await openSession('[Result "*"]\n\n1. e4 *');
  final settings = SettingsStore();
  final explorer = explorerOver(fixture.session, settings: settings);
  final layout = ActionLayout(newWorkspaceTabs(), explorer);
  addTearDown(() {
    layout.dispose();
    explorer.dispose();
    settings.dispose();
    fixture.dispose();
  });
  await tester.binding.setSurfaceSize(const Size(900, 680));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: darkTheme(),
      home: Scaffold(
        body: ActionPanes(
          layout: layout,
          body: (_, index, tab) => Text('Body $index ${tab.title}'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return layout;
}

Future<void> rightClick(WidgetTester tester, Finder target) async {
  await tester.tap(target, buttons: kSecondaryMouseButton);
  await tester.pumpAndSettle();
}

Finder pane(int index) => find.byKey(ValueKey('action-pane-$index'));
Finder tabIn(int index, String name) =>
    find.descendant(of: pane(index), matching: find.text(name));

void main() {
  testWidgets('the builder starts with Moves over the Explorer and '
      'Expectimax beside them, all in view', (tester) async {
    final layout = await pumpPanes(tester);
    layout.startBuilding();
    await tester.pumpAndSettle();
    expect(layout.count, 3);
    expect(find.text('Body 2 Moves'), findsOneWidget);
    expect(find.text('Body 0 Explorer'), findsOneWidget);
    expect(find.text('Body 1 Expectimax'), findsOneWidget);
    final moves = tester.getRect(pane(2));
    final explorer = tester.getRect(pane(0));
    final search = tester.getRect(pane(1));
    expect(moves.bottom, lessThanOrEqualTo(explorer.top));
    expect(moves.left, explorer.left);
    expect(search.left, greaterThanOrEqualTo(moves.right));
    expect(search.height, greaterThan(moves.height));
    expect(layout.pane(0).isOpen(WorkspaceTab.moves), isFalse);
    expect(layout.pane(0).isOpen(WorkspaceTab.search), isFalse);
    layout.startBuilding();
    expect(layout.count, 3, reason: 'a second call changes nothing');
  });

  testWidgets(
    'right click splits the chosen tab and moves it to a named pane',
    (tester) async {
      final layout = await pumpPanes(tester);
      expect(find.byType(SegmentedButton<int>), findsNothing);
      await rightClick(tester, tabIn(0, 'Explorer'));
      await tester.tap(find.text('Split right'));
      await tester.pumpAndSettle();
      expect(layout.count, 2);
      expect(layout.pane(0).isOpen(WorkspaceTab.explorer), isFalse);
      expect(find.text('Body 1 Explorer'), findsOneWidget);
      expect(
        tester.getRect(pane(0)).right,
        lessThanOrEqualTo(tester.getRect(pane(1)).left),
      );
      await rightClick(tester, tabIn(0, 'Expectimax'));
      await tester.tap(find.text('Move to Right — Explorer'));
      await tester.pumpAndSettle();
      expect(layout.pane(0).open, [WorkspaceTab.moves]);
      expect(find.text('Body 1 Expectimax'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'right clicking an Open tab action offers split and pane destinations',
    (tester) async {
      final layout = await pumpPanes(tester);
      await tester.tap(find.byTooltip('Open tab'));
      await tester.pumpAndSettle();
      await rightClick(tester, find.widgetWithText(MenuItemButton, 'Replies'));
      await tester.tap(
        find.widgetWithText(PopupMenuItem<VoidCallback>, 'Split below'),
      );
      await tester.pumpAndSettle();
      expect(layout.count, 2);
      expect(layout.pane(1).selected, WorkspaceTab.replies);
      expect(
        tester.getRect(pane(0)).bottom,
        lessThanOrEqualTo(tester.getRect(pane(1)).top),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'drag reveals docking targets, snaps below, and cancels cleanly',
    (tester) async {
      final layout = await pumpPanes(tester);
      expect(find.text('Split below'), findsNothing);
      final drag = await tester.startGesture(
        tester.getCenter(tabIn(0, 'Explorer')),
      );
      await drag.moveBy(const Offset(0, 80));
      await tester.pump();
      final target = find.byKey(const ValueKey('dock-0-Split below'));
      expect(target, findsOneWidget);
      await drag.moveTo(tester.getCenter(target));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(layout.count, 2);
      expect(layout.pane(1).selected, WorkspaceTab.explorer);
      expect(find.text('Split below'), findsNothing);
      expect(
        tester.getRect(pane(0)).bottom,
        lessThanOrEqualTo(tester.getRect(pane(1)).top),
      );
      final cancel = await tester.startGesture(
        tester.getCenter(tabIn(0, 'Expectimax')),
      );
      await cancel.moveBy(const Offset(0, 80));
      await tester.pump();
      await cancel.moveTo(const Offset(-20, -20));
      await cancel.up();
      await tester.pumpAndSettle();
      expect(layout.count, 2);
      expect(layout.pane(0).isOpen(WorkspaceTab.search), isTrue);
      expect(find.text('Split below'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cross-pane tab drop moves the correct source and removes its empty pane',
    (tester) async {
      final layout = await pumpPanes(tester);
      layout.split(0, WorkspaceTab.explorer, PaneSplitDirection.right, from: 0);
      await tester.pumpAndSettle();
      final drag = await tester.startGesture(
        tester.getCenter(tabIn(1, 'Explorer')),
      );
      await drag.moveTo(tester.getCenter(tabIn(0, 'Expectimax')));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(layout.count, 1);
      expect(layout.pane(0).open, [
        WorkspaceTab.moves,
        WorkspaceTab.explorer,
        WorkspaceTab.search,
      ]);
      expect(layout.pane(0).selected, WorkspaceTab.explorer);
      expect(find.text('Split below'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'moving a lone secondary tab collapses its pane without opening another copy',
    (tester) async {
      final layout = await pumpPanes(tester);
      layout.split(0, WorkspaceTab.explorer, PaneSplitDirection.right, from: 0);
      layout.split(0, WorkspaceTab.replies, PaneSplitDirection.below);
      layout.move(1, 2, WorkspaceTab.explorer);
      expect(layout.visible, [0, 2]);
      expect(layout.pane(0).isOpen(WorkspaceTab.explorer), isFalse);
      expect(layout.pane(2).selected, WorkspaceTab.explorer);
      layout.move(0, 2, WorkspaceTab.search);
      layout.move(0, 2, WorkspaceTab.moves);
      expect(
        layout.pane(0).selected,
        WorkspaceTab.explorer,
        reason:
            'keep a reading tool in the primary pane, not collection Analysis',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'splits respect four-pane limit, preserve tools and independent explorers when joined',
    (tester) async {
      final layout = await pumpPanes(tester);
      layout.split(0, WorkspaceTab.explorer, PaneSplitDirection.right);
      layout.split(1, WorkspaceTab.moves, PaneSplitDirection.below);
      final keptExplorer = layout.explorer(2);
      layout.split(0, WorkspaceTab.replies, PaneSplitDirection.below);
      expect(layout.count, 4);
      expect(layout.canSplit(WorkspaceTab.moves), isFalse);
      expect(layout.canSplit(WorkspaceTab.analysis), isFalse);
      layout.split(0, WorkspaceTab.moves, PaneSplitDirection.below);
      expect(layout.count, 4);
      layout.closePane(1);
      expect(layout.explorer(2), same(keptExplorer));
      expect(layout.visible, contains(2));
      expect(layout.pane(0).isOpen(WorkspaceTab.explorer), isTrue);
      layout.joinAll();
      await tester.pumpAndSettle();
      expect(layout.count, 1);
      expect(layout.active, 0);
      expect(layout.pane(0).isOpen(WorkspaceTab.replies), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tabs have no close button; right click closes one, and a pane with it',
    (tester) async {
      final layout = await pumpPanes(tester);
      expect(find.byIcon(Icons.close), findsNothing);
      layout.split(0, WorkspaceTab.replies, PaneSplitDirection.right);
      await tester.pumpAndSettle();
      await rightClick(tester, tabIn(0, 'Explorer'));
      await tester.tap(find.textContaining('Close tab'));
      await tester.pumpAndSettle();
      expect(layout.pane(0).isOpen(WorkspaceTab.explorer), isFalse);
      await rightClick(tester, tabIn(1, 'Replies'));
      await tester.tap(find.textContaining('Close tab'));
      await tester.pumpAndSettle();
      expect(layout.count, 1);
      expect(layout.pane(0).isOpen(WorkspaceTab.replies), isFalse);
      layout.pane(0).close(WorkspaceTab.search);
      expect(layout.canClose(0, WorkspaceTab.moves), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a tab dropped on the empty end of another row joins it', (
    tester,
  ) async {
    final layout = await pumpPanes(tester);
    layout.split(0, WorkspaceTab.explorer, PaneSplitDirection.right, from: 0);
    await tester.pumpAndSettle();
    final row = tester.getRect(find.byKey(const ValueKey('tab-row-1')));
    final drag = await tester.startGesture(
      tester.getCenter(tabIn(0, 'Expectimax')),
    );
    await drag.moveTo(row.centerRight - const Offset(20, 0));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(layout.pane(1).open, [WorkspaceTab.explorer, WorkspaceTab.search]);
    expect(layout.pane(0).isOpen(WorkspaceTab.search), isFalse);
    expect(tester.takeException(), isNull);
  });
}
