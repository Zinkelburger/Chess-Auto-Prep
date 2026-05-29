import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/layout/edit_context_zone.dart';
import 'package:chess_auto_prep/widgets/layout/repertoire_mode.dart';

void main() {
  testWidgets('renders tab bar and switches injected content',
      (tester) async {
    final viewNotifier = ValueNotifier(EditContextView.browse);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 960,
            height: 400,
            child: EditContextZone(
              initialView: EditContextView.browse,
              selectedViewNotifier: viewNotifier,
              browseContent: const Text('Browse slot'),
              engineContent: const Text('Engine slot'),
              expectimaxContent: const Text('Expectimax slot'),
              linesContent: const Text('Lines slot'),
              treeContent: const Text('Tree slot'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Browse'), findsOneWidget);
    expect(find.text('Engine'), findsOneWidget);
    expect(find.text('Expectimax'), findsOneWidget);
    expect(find.text('Lines'), findsOneWidget);
    expect(find.text('Tree'), findsOneWidget);
    expect(find.text('Browse slot'), findsOneWidget);

    await tester.tap(find.text('Engine'));
    await tester.pumpAndSettle();

    expect(find.text('Engine slot'), findsOneWidget);
    expect(viewNotifier.value, EditContextView.engine);

    await tester.tap(find.text('Tree'));
    await tester.pumpAndSettle();

    expect(find.text('Tree slot'), findsOneWidget);
    expect(viewNotifier.value, EditContextView.tree);
  });

  testWidgets('shows placeholder when browse content is omitted',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 480,
            height: 300,
            child: EditContextZone(
              initialView: EditContextView.browse,
              engineContent: Text('Engine only'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Browse not configured'), findsOneWidget);
  });
}
