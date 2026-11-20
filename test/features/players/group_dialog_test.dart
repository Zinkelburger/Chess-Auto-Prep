// New group and Edit group: what the dialog answers, and what it refuses.
// (A hand-edited date or rounds kept through a rename is in
// shell_players_test.dart, with the dialog opened from the group's menu.)
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/features/players/group_dialog.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PlayerGroup? answer;
  var answered = false;

  Future<void> open(WidgetTester tester, {PlayerGroup? group}) async {
    answer = null;
    answered = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                answer = await editGroup(context, group: group);
                answered = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  final name = find.widgetWithText(TextFormField, 'Group name');
  final date = find.widgetWithText(
    TextFormField,
    'Event date (YYYY-MM-DD, optional)',
  );

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text('Save group'));
    await tester.pumpAndSettle();
  }

  testWidgets('a new group is answered with its name, date and rounds', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('New group'), findsOneWidget);
    await tester.enterText(name, '  Club Open ');
    await tester.enterText(date, '2026-10-10');
    await tester.tap(find.byTooltip('Increase Rounds'));
    await tester.pump();
    await save(tester);
    expect(answered, isTrue);
    expect(answer!.name, 'Club Open');
    expect(answer!.fields['date'], '2026-10-10');
    expect(answer!.fields['rounds'], 6);
  });

  testWidgets('a new group with no date has none, and five rounds', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(name, 'Club');
    await tester.enterText(date, '   ');
    await save(tester);
    expect(answer!.fields['date'], isNull);
    expect(answer!.fields.containsKey('date'), isTrue);
    expect(answer!.fields['rounds'], 5);
  });

  testWidgets('a group needs a name and a real date written as asked', (
    tester,
  ) async {
    await open(tester);
    await save(tester);
    expect(answered, isFalse);
    expect(find.text('Please enter a name.'), findsOneWidget);
    await tester.enterText(name, 'Club');
    for (final wrong in [
      '2026-13-01',
      '2026-1-1',
      '10/10/2026',
      '2026-02-30',
    ]) {
      await tester.enterText(date, wrong);
      await save(tester);
      expect(answered, isFalse, reason: wrong);
      expect(find.text('Use a valid date: YYYY-MM-DD.'), findsOneWidget);
    }
    await tester.enterText(date, '2026-02-28');
    await save(tester);
    expect(answer!.fields['date'], '2026-02-28');
  });

  testWidgets('editing a group writes the fields changed, and keeps the rest '
      'as they were', (tester) async {
    final group = PlayerGroup.create(
      'Club',
    ).edited({'date': '2026-10-10', 'rounds': 7});
    await open(tester, group: group);
    expect(find.text('Edit group'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    await tester.tap(find.byTooltip('Decrease Rounds'));
    await tester.pump();
    await save(tester);
    expect(answer!.id, group.id);
    expect(answer!.fields['rounds'], 6);
    expect(answer!.fields['date'], '2026-10-10');

    await open(tester, group: group);
    await tester.enterText(date, '');
    await save(tester);
    expect(answer!.fields['date'], isNull);
    expect(answer!.fields['rounds'], 7);
  });
}
