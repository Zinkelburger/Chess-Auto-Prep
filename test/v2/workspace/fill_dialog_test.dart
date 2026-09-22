import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/fill_dialog.dart';
import 'package:chess_auto_prep/v2/workspace/fill_gaps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<Future<FillRequest?>> open(WidgetTester tester) async {
    late Future<FillRequest?> answer;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                answer = showFillDialog(context, elo: 2200, onceIn: 50),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return answer;
  }

  testWidgets('three numbers, prefilled, and one filled button', (
    tester,
  ) async {
    final answer = await open(tester);
    expect(find.text('Fill gaps from here'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Opponent rating'), findsOneWidget);
    expect(find.text('2200'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
    expect(find.text('Engine + human model'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
    await tester.tap(find.text('Fill'));
    await tester.pumpAndSettle();
    final request = await answer;
    expect(request?.elo, 2200);
    expect(request?.depthPlies, 8);
    expect(request?.onceIn, 50);
  });

  testWidgets('a number out of range says its range and keeps the dialog', (
    tester,
  ) async {
    final answer = await open(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'How deep (half-moves)'),
      '99',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Opponent rating'),
      '100',
    );
    await tester.tap(find.text('Fill'));
    await tester.pumpAndSettle();
    expect(find.text('1 to 64'), findsOneWidget);
    expect(find.text('1100 to 2900'), findsOneWidget);
    expect(find.text('Fill gaps from here'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'How deep (half-moves)'),
      '4',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Opponent rating'),
      '1500',
    );
    await tester.tap(find.text('Fill'));
    await tester.pumpAndSettle();
    final request = await answer;
    expect(request?.depthPlies, 4);
    expect(request?.elo, 1500);
  });

  testWidgets('cancel answers nothing', (tester) async {
    final answer = await open(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await answer, isNull);
  });
}
