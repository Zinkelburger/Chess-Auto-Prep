import 'package:chess_auto_prep/ui/status_bar.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<Color?> barColor(WidgetTester tester, {required bool problem}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: StatusBar(
            'Saved a copy as Main (2)',
            problem: problem,
            onClose: () {},
          ),
        ),
      ),
    );
    final bar = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(StatusBar),
            matching: find.byType(Container),
          )
          .first,
    );
    return bar.color;
  }

  testWidgets('a problem is drawn in the error colour', (tester) async {
    final color = await barColor(tester, problem: true);
    expect(color, darkTheme().colorScheme.errorContainer);
  });

  testWidgets('an outcome the user asked for gets no alarm colour', (
    tester,
  ) async {
    final color = await barColor(tester, problem: false);
    expect(color, isNot(darkTheme().colorScheme.errorContainer));
    expect(color, darkTheme().colorScheme.surfaceContainerHigh);
  });
}
