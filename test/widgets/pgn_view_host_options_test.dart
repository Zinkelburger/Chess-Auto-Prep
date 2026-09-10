import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'host menu opens reading options without a second settings icon',
    (tester) async {
      final controller = PgnViewerWidgetController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PgnViewerWidget(
              pgnText: '1. e4 e5 (1... c5) 2. Nf3 *',
              controller: controller,
              showReadingOptions: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Reading options'), findsNothing);
      expect(find.text('Main line'), findsOneWidget);
      final before = controller.currentFen;
      controller.showReadingOptions();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anchor near middle'));
      await tester.pumpAndSettle();
      expect(controller.currentFen, before);
      expect(find.text('Move list'), findsNothing);
    },
  );
}
