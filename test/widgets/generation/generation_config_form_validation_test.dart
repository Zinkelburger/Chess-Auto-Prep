// Start refuses a numeric knob it cannot use and names it, instead of
// quietly building with a default in its place.

import 'package:chess_auto_prep/models/eval_database_settings.dart';
import 'package:chess_auto_prep/widgets/generation/generation_config_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Finder _field(String labelPrefix) => find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      (w.decoration?.labelText?.startsWith(labelPrefix) ?? false),
);

void main() {
  late GlobalKey<GenerationConfigFormState> formKey;

  Future<void> pumpForm(WidgetTester tester) async {
    formKey = GlobalKey<GenerationConfigFormState>();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<EvalDatabaseSettings>.value(
            value: EvalDatabaseSettings.instance,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: GenerationConfigForm(
                isGenerating: false,
                playAsWhite: true,
                key: formKey,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a fresh form validates clean', (tester) async {
    await pumpForm(tester);
    expect(formKey.currentState!.validateBeforeStart(), isNull);
  });

  testWidgets('a decimal in a whole-number field is refused by name', (
    tester,
  ) async {
    await pumpForm(tester);

    await tester.enterText(_field('Max line length'), '20.5');
    await tester.pump();

    final error = formKey.currentState!.validateBeforeStart();
    expect(error, contains('Max line length'));
    expect(error, contains('whole number'));
    // The field says so too, under itself.
    expect(find.textContaining('Whole number'), findsOneWidget);
  });

  testWidgets('an out-of-range value is refused with the range', (
    tester,
  ) async {
    await pumpForm(tester);

    await tester.enterText(_field('Opponent rating'), '9000');
    await tester.pump();

    expect(
      formKey.currentState!.validateBeforeStart(),
      contains('Opponent rating: must be 500–3500'),
    );
  });

  testWidgets('an empty field is refused', (tester) async {
    await pumpForm(tester);

    await tester.enterText(_field('Engine depth'), '');
    await tester.pump();

    expect(
      formKey.currentState!.validateBeforeStart(),
      contains('Engine depth: enter a number'),
    );
  });
}
