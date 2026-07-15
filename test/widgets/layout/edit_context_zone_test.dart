import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/widgets/layout/edit_context_zone.dart';
import 'package:chess_auto_prep/widgets/layout/repertoire_mode.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('renders panel chips and shows multiple injected panels', (
    tester,
  ) async {
    final viewsNotifier = ValueNotifier<Set<EditContextView>>({
      EditContextView.browse,
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 960,
            height: 400,
            child: EditContextZone(
              initialView: EditContextView.browse,
              selectedViewsNotifier: viewsNotifier,
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
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(FilterChip), findsWidgets);
    expect(find.text('Browse slot'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('edit_context_chip_engine')));
    await tester.pumpAndSettle();

    expect(find.text('Browse slot'), findsOneWidget);
    expect(find.text('Engine slot'), findsOneWidget);
    expect(viewsNotifier.value, {
      EditContextView.browse,
      EditContextView.engine,
    });
  });

  testWidgets('two visible panels in default layout show column headers', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 960,
            height: 400,
            child: EditContextZone(
              initialView: EditContextView.browse,
              browseContent: const Text('Browse slot'),
              engineContent: const Text('Engine slot'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('edit_context_chip_engine')));
    await tester.pumpAndSettle();
    expect(find.text('Browse slot'), findsOneWidget);
    expect(find.text('Engine slot'), findsOneWidget);
  });

  testWidgets('deselecting a chip hides panel but keeps at least one', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 960,
            height: 400,
            child: EditContextZone(
              initialView: EditContextView.browse,
              browseContent: const Text('Browse slot'),
              engineContent: const Text('Engine slot'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('edit_context_chip_engine')));
    await tester.pumpAndSettle();
    expect(find.text('Engine slot'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('edit_context_chip_browse')));
    await tester.pumpAndSettle();

    expect(find.text('Browse slot'), findsNothing);
    expect(find.text('Engine slot'), findsOneWidget);
  });

  testWidgets('shows placeholder when browse content is omitted', (
    tester,
  ) async {
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

  testWidgets('expectimax slot updates when parent passes new content', (
    tester,
  ) async {
    final gen = ValueNotifier(0);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 300,
            child: ValueListenableBuilder<int>(
              valueListenable: gen,
              builder: (context, n, _) => EditContextZone(
                initialView: EditContextView.expectimax,
                expectimaxContent: Text('Expectimax gen $n'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Expectimax gen 0'), findsOneWidget);

    gen.value = 1;
    await tester.pumpAndSettle();

    expect(find.text('Expectimax gen 0'), findsNothing);
    expect(find.text('Expectimax gen 1'), findsOneWidget);
  });

  testWidgets('layout button opens arrange sheet', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 400,
            child: EditContextZone(
              initialView: EditContextView.browse,
              browseContent: const Text('Browse slot'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Arrange panes'));
    await tester.pumpAndSettle();

    expect(find.text('Pane layout'), findsOneWidget);
    expect(find.text('Column 1'), findsOneWidget);
  });
}
