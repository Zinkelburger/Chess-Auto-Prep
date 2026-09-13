import 'package:chess_auto_prep/core/slice_filter_controller.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/slice/position_filter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'FEN hover previews the board and clears on exit, edit and disposal',
    (tester) async {
      final controller = SliceFilterController();
      addTearDown(controller.dispose);
      controller.positionText.text = '1. e4';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 500,
                child: PositionFilter(controller: controller),
              ),
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(TextField)));
      await tester.pumpAndSettle();
      expect(find.byType(ChessBoardWidget), findsOneWidget);
      expect(find.byIcon(Icons.visibility_outlined), findsNothing);
      expect(find.byIcon(Icons.check_circle), findsNothing);
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(find.byType(ChessBoardWidget), findsNothing);
      await mouse.moveTo(tester.getCenter(find.byType(TextField)));
      await tester.pumpAndSettle();
      controller.positionText.text = 'not a position';
      await tester.pumpAndSettle();
      expect(find.byType(ChessBoardWidget), findsNothing);
      await mouse.moveTo(Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(TextField)));
      await tester.pumpAndSettle();
      expect(find.byType(ChessBoardWidget), findsNothing);
      controller.positionText.text = '1. d4';
      await tester.pumpAndSettle();
      await mouse.moveTo(Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(TextField)));
      await tester.pumpAndSettle();
      expect(find.byType(ChessBoardWidget), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
