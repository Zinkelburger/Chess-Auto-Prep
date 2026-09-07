import 'package:chess_auto_prep/widgets/common/choice_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const items = [
    ChoiceItem(value: 'sicilian', label: 'Sicilian Defence'),
    ChoiceItem(value: 'french', label: 'French Defence'),
    ChoiceItem(value: 'caro', label: 'Caro-Kann', subtitle: 'Solid'),
    ChoiceItem(value: 'pirc', label: 'Pirc Defence'),
  ];

  Future<String?> pump(WidgetTester tester, {String? value}) async {
    String? picked = value;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Scaffold(
          body: StatefulBuilder(
            // The other box sits above the field: the open list hangs
            // below it and would otherwise cover whatever came next.
            builder: (context, setState) => Column(
              children: [
                const TextField(key: Key('other')),
                SizedBox(
                  width: 260,
                  child: ChoiceField<String>(
                    key: const Key('field'),
                    label: 'Opening',
                    value: picked,
                    items: items,
                    onChanged: (v) => setState(() => picked = v),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return picked;
  }

  testWidgets('shows the current choice and the whole list on click', (
    tester,
  ) async {
    await pump(tester, value: 'french');
    expect(find.text('French Defence'), findsOneWidget);
    expect(find.text('Sicilian Defence'), findsNothing);

    await tester.tap(find.byKey(const Key('field')));
    await tester.pumpAndSettle();
    expect(find.text('Sicilian Defence'), findsOneWidget);
    expect(find.text('Pirc Defence'), findsOneWidget);
    expect(find.text('Solid'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('typing filters by plain contains and Enter takes the top hit', (
    tester,
  ) async {
    await pump(tester, value: 'french');
    await tester.enterText(find.byKey(const Key('field')), 'kann');
    await tester.pumpAndSettle();
    expect(find.text('Caro-Kann'), findsOneWidget);
    expect(find.text('Pirc Defence'), findsNothing);
    expect(find.text('Sicilian Defence'), findsNothing);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      tester.widget<ChoiceField<String>>(find.byKey(const Key('field'))).value,
      'caro',
    );
    // The list closed and the box shows the new choice.
    expect(find.text('Pirc Defence'), findsNothing);
    expect(find.text('Caro-Kann'), findsOneWidget);
  });

  testWidgets('a query that matches nothing says so and keeps the choice', (
    tester,
  ) async {
    await pump(tester, value: 'french');
    await tester.enterText(find.byKey(const Key('field')), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      tester.widget<ChoiceField<String>>(find.byKey(const Key('field'))).value,
      'french',
    );
    expect(find.text('French Defence'), findsOneWidget);
  });

  testWidgets('arrow keys move the highlight; Escape and blur revert', (
    tester,
  ) async {
    await pump(tester, value: 'sicilian');
    await tester.tap(find.byKey(const Key('field')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      tester.widget<ChoiceField<String>>(find.byKey(const Key('field'))).value,
      'caro',
    );

    // Half-typed, then Escape: the text goes back to the choice.
    await tester.enterText(find.byKey(const Key('field')), 'pi');
    await tester.pumpAndSettle();
    expect(find.text('Pirc Defence'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Pirc Defence'), findsNothing);
    expect(find.text('Caro-Kann'), findsOneWidget);

    // Half-typed, then focus moves on: same.
    await tester.enterText(find.byKey(const Key('field')), 'fr');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('other')));
    await tester.pumpAndSettle();
    expect(find.text('French Defence'), findsNothing);
    expect(find.text('Caro-Kann'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a disabled field neither opens nor changes', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Scaffold(
          body: ChoiceField<String>(
            key: const Key('field'),
            value: 'french',
            items: items,
            enabled: false,
            onChanged: (_) => fail('must not change'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('field')), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Sicilian Defence'), findsNothing);
  });

  testWidgets('mouse arrow opens a stable list and supports repeated clicks', (
    tester,
  ) async {
    await pump(tester, value: 'french');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.down(tester.getCenter(find.byTooltip('Show all')));
    await tester.pump(const Duration(milliseconds: 100));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.text('Sicilian Defence'), findsOneWidget);
    await mouse.down(tester.getCenter(find.text('Sicilian Defence')));
    await tester.pump(const Duration(milliseconds: 100));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(
      tester.widget<ChoiceField<String>>(find.byKey(const Key('field'))).value,
      'sicilian',
    );
    await tester.tap(find.byTooltip('Show all'));
    await tester.pumpAndSettle();
    expect(find.text('Pirc Defence'), findsOneWidget);
    await tester.tap(find.byTooltip('Close list'));
    await tester.pumpAndSettle();
    expect(find.text('Pirc Defence'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.all());
}
