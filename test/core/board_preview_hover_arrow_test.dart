import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/models/board_annotation.dart';

void main() {
  group('BoardPreviewController.setHoverArrow', () {
    late BoardPreviewController controller;
    late int notifications;

    setUp(() {
      controller = BoardPreviewController();
      notifications = 0;
      controller.addListener(() => notifications++);
    });

    tearDown(() => controller.dispose());

    test('starts with no arrow', () {
      expect(controller.hoverArrow, isNull);
    });

    test('shows an arrow immediately and clears it on null', () {
      final e4 = BoardAnnotation.arrowFromUci('e2e4');
      controller.setHoverArrow(e4);
      expect(controller.hoverArrow, e4);
      expect(notifications, 1);

      controller.setHoverArrow(null);
      expect(controller.hoverArrow, isNull);
      expect(notifications, 2);
    });

    test('does not re-notify for the same arrow', () {
      controller.setHoverArrow(BoardAnnotation.arrowFromUci('e2e4'));
      controller.setHoverArrow(BoardAnnotation.arrowFromUci('e2e4'));
      expect(notifications, 1);

      controller.setHoverArrow(null);
      controller.setHoverArrow(null);
      expect(notifications, 2);
    });

    test('leaves the position preview alone', () {
      controller.setHoverArrow(BoardAnnotation.arrowFromUci('g1f3'));
      expect(controller.isPreview, isFalse);
      expect(controller.previewFen, isNull);
    });
  });
}
