import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/features/repertoire/controllers/repertoire_layout_prefs.dart';
import 'package:chess_auto_prep/models/board_size.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('persistence', () {
    test('defaults to an expanded panel and a large board', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);

      await prefs.load();

      expect(prefs.analysisCollapsed, isFalse);
      expect(prefs.outlinePanelWidth, isNull);
      expect(prefs.boardSize, BoardSize.large);
    });

    test('reads a saved layout back', () async {
      SharedPreferences.setMockInitialValues({
        RepertoireLayoutPrefs.analysisCollapsedKey: true,
        RepertoireLayoutPrefs.outlineWidthKey: 340.0,
        RepertoireLayoutPrefs.boardSizeKey: 'small',
      });
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);

      await prefs.load();

      expect(prefs.analysisCollapsed, isTrue);
      expect(prefs.outlinePanelWidth, 340.0);
      expect(prefs.boardSize, BoardSize.small);
    });

    test('opens the Database pane on the source you last picked', () async {
      SharedPreferences.setMockInitialValues({
        RepertoireLayoutPrefs.databaseSourceKey: 4,
      });
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);

      await prefs.load();

      expect(prefs.databaseSource, 4);
    });

    test('defaults the Database pane to engine evals', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);

      await prefs.load();

      expect(prefs.databaseSource, RepertoireLayoutPrefs.defaultDatabaseSource);
    });

    test('a source outside the menu falls back to the default', () async {
      for (final stored in [-1, 5, 99]) {
        SharedPreferences.setMockInitialValues({
          RepertoireLayoutPrefs.databaseSourceKey: stored,
        });
        final prefs = RepertoireLayoutPrefs();
        addTearDown(prefs.dispose);

        await prefs.load();

        expect(
          prefs.databaseSource,
          RepertoireLayoutPrefs.defaultDatabaseSource,
          reason: 'stored $stored must not index the source list out of range',
        );
      }
    });

    test('picking a source writes it back for the next launch', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);
      await prefs.load();

      await prefs.setDatabaseSource(1);
      expect(prefs.databaseSource, 1);

      final reopened = RepertoireLayoutPrefs();
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.databaseSource, 1);
    });

    test('an unknown board size falls back to the classic layout', () async {
      SharedPreferences.setMockInitialValues({
        RepertoireLayoutPrefs.boardSizeKey: 'gigantic',
      });
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);

      await prefs.load();

      expect(prefs.boardSize, BoardSize.large);
    });

    test('collapsing and board size are written through', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);
      await prefs.load();

      await prefs.setAnalysisCollapsed(true);
      await prefs.setBoardSize(BoardSize.medium);

      final store = await SharedPreferences.getInstance();
      expect(store.getBool(RepertoireLayoutPrefs.analysisCollapsedKey), isTrue);
      expect(store.getString(RepertoireLayoutPrefs.boardSizeKey), 'medium');
    });

    test('a drag repaints but only the drag end reaches disk', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);
      await prefs.load();
      var notifications = 0;
      prefs.addListener(() => notifications++);

      prefs.dragOutlinePanelWidth(300);
      prefs.dragOutlinePanelWidth(320);

      expect(notifications, 2);
      final store = await SharedPreferences.getInstance();
      expect(store.getDouble(RepertoireLayoutPrefs.outlineWidthKey), isNull);

      await prefs.saveOutlinePanelWidth();
      expect(store.getDouble(RepertoireLayoutPrefs.outlineWidthKey), 320.0);
    });

    test('setting the value already held is not a change', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);
      await prefs.load();
      var notifications = 0;
      prefs.addListener(() => notifications++);

      await prefs.setAnalysisCollapsed(false);
      await prefs.setBoardSize(BoardSize.large);
      prefs.dragOutlinePanelWidth(300);
      prefs.dragOutlinePanelWidth(300);

      expect(notifications, 1);
    });

    test('toggling flips the collapsed state', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);
      await prefs.load();

      await prefs.toggleAnalysisCollapsed();
      expect(prefs.analysisCollapsed, isTrue);
      await prefs.toggleAnalysisCollapsed();
      expect(prefs.analysisCollapsed, isFalse);
    });
  });

  test('database dock resizing is bounded and restored', () async {
    final prefs = RepertoireLayoutPrefs();
    prefs.dragDatabaseHeight(900, 700);
    expect(prefs.resolveDatabaseHeight(700), closeTo(385, .001));
    await prefs.saveDatabaseHeight();
    final restored = RepertoireLayoutPrefs();
    await restored.load();
    expect(restored.resolveDatabaseHeight(700), closeTo(385, .001));
    prefs.dispose();
    restored.dispose();
  });

  group('panel width', () {
    test('follows a proportional default until the user drags', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);
      await prefs.load();

      // 18% of the body, bounded to a readable range.
      expect(prefs.resolveOutlinePanelWidth(1400), closeTo(252, 0.01));
      expect(prefs.resolveOutlinePanelWidth(1000), 220); // floor
      expect(prefs.resolveOutlinePanelWidth(3000), 280); // ceiling
    });

    test('a dragged width wins, inside the allowed range', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);
      await prefs.load();

      prefs.dragOutlinePanelWidth(500);
      expect(prefs.resolveOutlinePanelWidth(1400), 500);

      // Never narrower than the minimum...
      prefs.dragOutlinePanelWidth(50);
      expect(
        prefs.resolveOutlinePanelWidth(1400),
        RepertoireLayoutPrefs.minPanelWidth,
      );

      // ...and never more than 45% of the body, so the PGN column survives.
      prefs.dragOutlinePanelWidth(5000);
      expect(prefs.resolveOutlinePanelWidth(1400), closeTo(630, 0.01));
    });

    test('the max width never inverts on an implausibly narrow body', () {
      // clamp() throws when its lower bound exceeds its upper one; the wide
      // layout only runs above the compact breakpoint, but the arithmetic
      // should not be the thing that decides that.
      expect(
        RepertoireLayoutPrefs.maxOutlinePanelWidth(100),
        greaterThanOrEqualTo(RepertoireLayoutPrefs.minPanelWidth),
      );
    });
  });

  group('board zone width', () {
    test('is the largest square that fits, capped at half the body', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);
      await prefs.load();

      // Height-bound: a tall, wide body.
      expect(
        prefs.boardZoneWidth(availableWidth: 1600, availableHeight: 700),
        700,
      );
      // Width-bound: the board may never take more than half the body.
      expect(
        prefs.boardZoneWidth(availableWidth: 1000, availableHeight: 900),
        500,
      );
    });

    test('scales down with the board size preset', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);
      await prefs.load();

      await prefs.setBoardSize(BoardSize.small);
      expect(
        prefs.boardZoneWidth(availableWidth: 1600, availableHeight: 700),
        closeTo(700 * BoardSize.small.widthFactor, 0.01),
      );
    });
  });
}
