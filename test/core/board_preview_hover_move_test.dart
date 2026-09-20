import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';

void main() {
  group('BoardPreviewController.setHoverMove', () {
    late BoardPreviewController controller;
    late int notifications;

    setUp(() {
      controller = BoardPreviewController();
      notifications = 0;
      controller.addListener(() => notifications++);
    });

    tearDown(() => controller.dispose());

    test('starts with nothing tinted', () {
      expect(controller.hoverSquares, isEmpty);
    });

    test('tints from/to immediately and clears them on null', () {
      controller.setHoverMove('e2e4');
      expect(controller.hoverSquares, {'e2', 'e4'});
      expect(notifications, 1);

      controller.setHoverMove(null);
      expect(controller.hoverSquares, isEmpty);
      expect(notifications, 2);
    });

    test('ignores the promotion suffix', () {
      controller.setHoverMove('e7e8q');
      expect(controller.hoverSquares, {'e7', 'e8'});
    });

    test('does not re-notify for the same move', () {
      controller.setHoverMove('e2e4');
      controller.setHoverMove('e2e4');
      expect(notifications, 1);

      controller.setHoverMove(null);
      controller.setHoverMove(null);
      expect(notifications, 2);
    });

    test('leaves the position preview alone', () {
      controller.setHoverMove('g1f3');
      expect(controller.isPreview, isFalse);
      expect(controller.previewFen, isNull);
    });
  });
}
