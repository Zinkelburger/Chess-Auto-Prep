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

      expect(prefs.linesPanelCollapsed, isFalse);
      expect(prefs.linesPanelWidth, isNull);
      expect(prefs.boardSize, BoardSize.large);
    });

    test('reads a saved layout back', () async {
      SharedPreferences.setMockInitialValues({
        RepertoireLayoutPrefs.collapsedKey: true,
        RepertoireLayoutPrefs.widthKey: 340.0,
        RepertoireLayoutPrefs.boardSizeKey: 'small',
      });
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);

      await prefs.load();

      expect(prefs.linesPanelCollapsed, isTrue);
      expect(prefs.linesPanelWidth, 340.0);
      expect(prefs.boardSize, BoardSize.small);
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

      await prefs.setLinesPanelCollapsed(true);
      await prefs.setBoardSize(BoardSize.medium);

      final store = await SharedPreferences.getInstance();
      expect(store.getBool(RepertoireLayoutPrefs.collapsedKey), isTrue);
      expect(store.getString(RepertoireLayoutPrefs.boardSizeKey), 'medium');
    });

    test('a drag repaints but only the drag end reaches disk', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);
      await prefs.load();
      var notifications = 0;
      prefs.addListener(() => notifications++);

      prefs.dragLinesPanelWidth(300);
      prefs.dragLinesPanelWidth(320);

      expect(notifications, 2);
      final store = await SharedPreferences.getInstance();
      expect(store.getDouble(RepertoireLayoutPrefs.widthKey), isNull);

      await prefs.saveLinesPanelWidth();
      expect(store.getDouble(RepertoireLayoutPrefs.widthKey), 320.0);
    });

    test('setting the value already held is not a change', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);
      await prefs.load();
      var notifications = 0;
      prefs.addListener(() => notifications++);

      await prefs.setLinesPanelCollapsed(false);
      await prefs.setBoardSize(BoardSize.large);
      prefs.dragLinesPanelWidth(300);
      prefs.dragLinesPanelWidth(300);

      expect(notifications, 1);
    });

    test('toggling flips the collapsed state', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);
      await prefs.load();

      await prefs.toggleLinesPanelCollapsed();
      expect(prefs.linesPanelCollapsed, isTrue);
      await prefs.toggleLinesPanelCollapsed();
      expect(prefs.linesPanelCollapsed, isFalse);
    });
  });

  group('panel width', () {
    test('follows a proportional default until the user drags', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);
      await prefs.load();

      // 24% of the body, bounded to a readable range.
      expect(prefs.resolveLinesPanelWidth(1400), closeTo(336, 0.01));
      expect(prefs.resolveLinesPanelWidth(1000), 260); // floor
      expect(prefs.resolveLinesPanelWidth(3000), 400); // ceiling
    });

    test('a dragged width wins, inside the allowed range', () async {
      final prefs = RepertoireLayoutPrefs();
      addTearDown(prefs.dispose);
      await prefs.load();

      prefs.dragLinesPanelWidth(500);
      expect(prefs.resolveLinesPanelWidth(1400), 500);

      // Never narrower than the minimum...
      prefs.dragLinesPanelWidth(50);
      expect(
        prefs.resolveLinesPanelWidth(1400),
        RepertoireLayoutPrefs.minPanelWidth,
      );

      // ...and never more than 45% of the body, so the PGN column survives.
      prefs.dragLinesPanelWidth(5000);
      expect(prefs.resolveLinesPanelWidth(1400), closeTo(630, 0.01));
    });

    test('the max width never inverts on an implausibly narrow body', () {
      // clamp() throws when its lower bound exceeds its upper one; the wide
      // layout only runs above the compact breakpoint, but the arithmetic
      // should not be the thing that decides that.
      expect(
        RepertoireLayoutPrefs.maxLinesPanelWidth(100),
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
