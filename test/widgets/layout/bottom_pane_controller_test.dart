import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/layout/bottom_pane_controller.dart';

/// The bottom pane's open/closed state used to live in `BottomPaneState` and
/// was driven from the screen through `GlobalKey<BottomPaneState>`, so none of
/// it could be tested without pumping the whole repertoire screen. As a
/// controller it is plain state, and the toggle rules — which are what a user
/// actually feels when pressing a shortcut twice — are checkable directly.
void main() {
  group('opening and closing', () {
    test('starts collapsed', () {
      final c = BottomPaneController();
      expect(c.isCollapsed, isTrue);
    });

    test('open reveals the requested tab', () {
      final c = BottomPaneController();
      c.open(BottomPaneTab.jobs);
      expect(c.isCollapsed, isFalse);
      expect(c.activeTab, BottomPaneTab.jobs);
    });

    test('open on an already-showing tab does not notify again', () {
      final c = BottomPaneController();
      c.open(BottomPaneTab.jobs);
      var notifications = 0;
      c.addListener(() => notifications++);

      c.open(BottomPaneTab.jobs);

      expect(notifications, 0, reason: 'nothing changed, so nothing to redraw');
    });

    test('close on an already-collapsed pane does not notify', () {
      final c = BottomPaneController();
      var notifications = 0;
      c.addListener(() => notifications++);
      c.close();
      expect(notifications, 0);
    });

    test('closing keeps the tab, so reopening returns where you were', () {
      final c = BottomPaneController();
      c.open(BottomPaneTab.jobs);
      c.close();
      c.toggle();
      expect(c.activeTab, BottomPaneTab.jobs);
    });
  });

  group('toggle', () {
    test('opens when collapsed', () {
      final c = BottomPaneController();
      c.toggle(BottomPaneTab.findings);
      expect(c.isShowing(BottomPaneTab.findings), isTrue);
    });

    test('switches when open on a different tab', () {
      final c = BottomPaneController();
      c.open(BottomPaneTab.findings);
      c.toggle(BottomPaneTab.jobs);
      expect(c.isCollapsed, isFalse);
      expect(c.activeTab, BottomPaneTab.jobs);
    });

    test('closes when open on the same tab — the shortcut is a toggle', () {
      final c = BottomPaneController();
      c.open(BottomPaneTab.jobs);
      c.toggle(BottomPaneTab.jobs);
      expect(c.isCollapsed, isTrue);
    });

    test('with no tab closes an open pane', () {
      final c = BottomPaneController();
      c.open(BottomPaneTab.jobs);
      c.toggle();
      expect(c.isCollapsed, isTrue);
    });
  });

  group('isShowing', () {
    test('is false for every tab while collapsed', () {
      final c = BottomPaneController();
      for (final tab in BottomPaneTab.values) {
        expect(c.isShowing(tab), isFalse);
      }
    });

    test('is true only for the visible tab', () {
      final c = BottomPaneController();
      c.open(BottomPaneTab.jobs);
      expect(c.isShowing(BottomPaneTab.jobs), isTrue);
      expect(c.isShowing(BottomPaneTab.findings), isFalse);
    });
  });

  group('height', () {
    test('is clamped to the maximum fraction', () {
      final c = BottomPaneController();
      c.setHeightFraction(0.95);
      expect(c.heightFraction, BottomPaneController.maxHeightFraction);
    });

    test('never goes negative', () {
      final c = BottomPaneController();
      c.setHeightFraction(-1);
      expect(c.heightFraction, 0.0);
    });

    test('an unchanged fraction does not notify', () {
      final c = BottomPaneController();
      var notifications = 0;
      c.addListener(() => notifications++);
      c.setHeightFraction(c.heightFraction);
      expect(notifications, 0);
    });
  });
}
