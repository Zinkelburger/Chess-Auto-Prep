import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/position_analysis_widget.dart';

void main() {
  testWidgets('stacks analysis panes cleanly on narrow layouts', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 800,
              child: const PositionAnalysisWidget(
                playerIsWhite: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Positions'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    expect(find.byType(PositionAnalysisWidget), findsOneWidget);
  });
}
