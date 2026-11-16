// The one search box: not focused unless asked, and a clear button only
// once there is something to clear.
import 'package:chess_auto_prep/ui/search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late TextEditingController controller;
  late List<String> changes;
  setUp(() {
    controller = TextEditingController();
    changes = [];
  });
  tearDown(() => controller.dispose());

  Future<void> show(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SearchField(
          controller: controller,
          hint: 'Search games',
          onChanged: changes.add,
        ),
      ),
    ),
  );

  testWidgets('is not focused unless asked', (tester) async {
    await show(tester);
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.focusNode.hasFocus, isFalse);
  });

  testWidgets('offers to clear only what there is, and says it was cleared', (
    tester,
  ) async {
    await show(tester);
    expect(find.byTooltip('Clear search'), findsNothing);
    await tester.enterText(find.byType(TextField), 'Carlsen');
    await tester.pump();
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    expect(controller.text, isEmpty);
    expect(changes, ['Carlsen', '']);
    expect(find.byTooltip('Clear search'), findsNothing);
  });
}
