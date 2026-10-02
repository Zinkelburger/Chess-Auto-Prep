import 'dart:async';

import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/features/trainer/lesson_view.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/features/library/outline_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

Finder _pane(int index) => find.byKey(ValueKey('action-pane-$index'));

void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  Future<void> open(WidgetTester tester, Mode mode, Size window) async {
    await w.pumpShell(tester);
    await tester.binding.setSurfaceSize(window);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    unawaited(w.requests.open(kidMain));
    await tester.pumpAndSettle();
    w.requests.switchTo(mode);
    await tester.pumpAndSettle();
  }

  testWidgets('larger text and extreme board resizing keep controls readable', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester, Mode.repertoires, const Size(1280, 720));
    final divider = find.byKey(const ValueKey('board-card-divider'));
    await tester.drag(divider, const Offset(-600, 0));
    await tester.pumpAndSettle();
    final board = tester.getRect(find.byKey(const ValueKey('board-area')));
    expect(board.width, greaterThanOrEqualTo(boardPaneMinWidth));
    await tester.drag(divider, const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    w.requests.switchTo(Mode.trainer);
    await tester.pumpAndSettle();
    w.lineTrainer.learn();
    await tester.pumpAndSettle();
    expect(find.text('Back to lines'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // The default window, and the height the release notes quote.
  for (final window in [const Size(1280, 720), const Size(1280, 800)]) {
    final name = '${window.width.round()}×${window.height.round()}';

    testWidgets('at $name the builder with a chapter open gives Moves and '
        'Expectimax their room beside the list and the outline', (
      tester,
    ) async {
      await open(tester, Mode.repertoires, window);
      expect(find.byType(OutlinePanel), findsOneWidget);
      final moves = tester.getRect(_pane(0));
      final search = tester.getRect(_pane(1));
      expect(moves.width, greaterThanOrEqualTo(paneMinWidth));
      expect(
        search.width,
        greaterThanOrEqualTo(searchPaneMinWidth),
        reason: 'narrower, the Expectimax pane would scroll sideways',
      );
      expect(search.right, lessThanOrEqualTo(window.width));
      expect(tester.takeException(), isNull);
    });

    testWidgets('at $name a tool opened in the trainer goes under the '
        'lesson, which keeps its control and way out in view', (tester) async {
      await open(tester, Mode.trainer, window);
      w.lineTrainer.learn();
      await tester.pumpAndSettle();
      expect(find.byType(LessonView), findsOneWidget);
      await tester.tap(find.byTooltip('Open tools and arrange panes'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Explorer'));
      await tester.pumpAndSettle();
      final lesson = tester.getRect(_pane(0));
      expect(tester.getRect(_pane(1)).top, greaterThanOrEqualTo(lesson.bottom));
      expect(find.byType(LessonView), findsOneWidget);
      for (final control in [
        find.widgetWithText(FilledButton, 'Next'),
        find.text('Back to lines'),
      ]) {
        final rect = tester.getRect(control);
        expect(
          lesson.contains(rect.topLeft) && lesson.contains(rect.bottomRight),
          isTrue,
          reason: '$control at $rect is outside the lesson pane $lesson',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
