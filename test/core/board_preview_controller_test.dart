import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';

void main() {
  group('BoardPreviewController', () {
    late BoardPreviewController controller;

    setUp(() {
      controller = BoardPreviewController();
    });

    tearDown(() {
      controller.dispose();
    });

    test('starts with no preview', () {
      expect(controller.isPreview, false);
      expect(controller.previewFen, isNull);
      expect(controller.previewMoves, isNull);
      expect(controller.target, BoardPreviewTarget.mainBoard);
      expect(controller.lastMoveUci, isNull);
    });

    testWidgets('setPreview debounces and fires after 80ms', (
      WidgetTester tester,
    ) async {
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      controller.setPreview('fen1', moves: ['e4']);
      expect(controller.isPreview, false);

      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.isPreview, false);

      await tester.pump(const Duration(milliseconds: 40));
      expect(controller.isPreview, true);
      expect(controller.previewFen, 'fen1');
      expect(controller.previewMoves, ['e4']);
      expect(controller.target, BoardPreviewTarget.mainBoard);
      expect(notifyCount, 1);
    });

    testWidgets('floating target and lastMoveUci are stored', (
      WidgetTester tester,
    ) async {
      controller.setPreview(
        'fen2',
        target: BoardPreviewTarget.floating,
        lastMoveUci: 'e2e4',
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.target, BoardPreviewTarget.floating);
      expect(controller.lastMoveUci, 'e2e4');
    });

    testWidgets('rapid setPreview calls - only last fires', (
      WidgetTester tester,
    ) async {
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      controller.setPreview('fen1');
      await tester.pump(const Duration(milliseconds: 30));
      controller.setPreview('fen2');
      await tester.pump(const Duration(milliseconds: 30));
      controller.setPreview('fen3');

      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.previewFen, 'fen3');
      expect(notifyCount, 1);
    });

    testWidgets('clearPreview is immediate', (WidgetTester tester) async {
      controller.setPreview('fen1');
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.isPreview, true);

      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      controller.clearPreview();
      expect(controller.isPreview, false);
      expect(controller.previewFen, isNull);
      expect(notifyCount, 1);
    });

    testWidgets('clearPreview cancels pending debounce', (
      WidgetTester tester,
    ) async {
      controller.setPreview('fen1');
      await tester.pump(const Duration(milliseconds: 30));
      controller.clearPreview();

      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.isPreview, false);
    });

    test('clearPreview no-ops when no preview active', () {
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      controller.clearPreview();
      expect(notifyCount, 0);
    });
  });
}
