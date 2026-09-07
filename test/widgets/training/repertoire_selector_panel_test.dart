import 'package:chess_auto_prep/widgets/training/repertoire_selector_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(RepertoireSelectorPanel panel) =>
      MaterialApp(home: Scaffold(body: panel));

  testWidgets('an empty repertoire offers the Builder as the way forward', (
    tester,
  ) async {
    var opened = 0;
    var selected = 0;
    await tester.pumpWidget(
      host(
        RepertoireSelectorPanel(
          isLoading: false,
          error: 'No trainable lines found.',
          hasLines: false,
          canStartTraining: false,
          onSelectRepertoire: () => selected++,
          onOpenInBuilder: () => opened++,
        ),
      ),
    );

    expect(find.text('No trainable lines found.'), findsOneWidget);
    await tester.tap(find.text('Add lines in Repertoire Builder'));
    await tester.tap(find.text('Select Repertoire'));
    expect(opened, 1);
    expect(selected, 1);
  });

  testWidgets('without a Builder target only Select Repertoire is offered', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        RepertoireSelectorPanel(
          isLoading: false,
          error: 'Could not read the file.',
          hasLines: false,
          canStartTraining: false,
          onSelectRepertoire: () {},
        ),
      ),
    );

    expect(find.text('Select Repertoire'), findsOneWidget);
    expect(find.text('Add lines in Repertoire Builder'), findsNothing);
  });
}
