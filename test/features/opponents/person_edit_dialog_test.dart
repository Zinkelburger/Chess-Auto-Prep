import 'dart:convert';

import 'package:chess_auto_prep/features/opponents/models/person_record.dart';
import 'package:chess_auto_prep/features/opponents/services/uscf_client.dart';
import 'package:chess_auto_prep/features/opponents/widgets/person_edit_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The editor's two US Chess buttons fill the form from the ratings server:
/// an ID gives the name and rating, a name gives IDs to pick from.
void main() {
  const hikaru = {
    'id': '12641216',
    'firstName': 'HIKARU',
    'lastName': 'NAKAMURA',
    'stateRep': 'NY',
    'ratings': [
      {'rating': 2846, 'ratingSystem': 'R'},
    ],
  };

  UscfClient fakeUscf() => UscfClient(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/members/12641216')) {
        return http.Response(jsonEncode(hikaru), 200);
      }
      if (request.url.query.contains('name=')) {
        return http.Response(
          jsonEncode({
            'items': [hikaru],
          }),
          200,
        );
      }
      return http.Response('', 404);
    }),
  );

  /// Opens the dialog; [result] is filled when it pops.
  Future<void> pump(
    WidgetTester tester,
    void Function(PersonRecord?) result, {
    PersonRecord? person,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result(
                  await showDialog<PersonRecord>(
                    context: context,
                    builder: (_) =>
                        PersonEditDialog(person: person, uscf: fakeUscf()),
                  ),
                );
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

  String fieldText(WidgetTester tester, String key) =>
      tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

  testWidgets('Look up fills the name and rating from the ID', (tester) async {
    PersonRecord? saved;
    await pump(tester, (r) => saved = r);
    await tester.enterText(find.byKey(const Key('person-uscf-id')), '12641216');
    await tester.tap(find.byKey(const Key('person-lookup-uscf')));
    await tester.pumpAndSettle();
    expect(fieldText(tester, 'person-name'), 'Hikaru Nakamura');
    expect(fieldText(tester, 'person-rating'), '2846');
    expect(find.text('Hikaru Nakamura · 2846 · NY'), findsOneWidget);
    await tester.tap(find.byKey(const Key('person-save')));
    await tester.pumpAndSettle();
    expect(saved!.name, 'Hikaru Nakamura');
    expect(saved!.uscfId, '12641216');
    expect(saved!.rating, 2846);
  });

  testWidgets('Find lists matches and picking one fills the ID', (
    tester,
  ) async {
    PersonRecord? saved;
    await pump(tester, (r) => saved = r);
    await tester.enterText(find.byKey(const Key('person-name')), 'nakamura');
    await tester.tap(find.byKey(const Key('person-find-uscf')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('uscf-match-12641216')));
    await tester.pumpAndSettle();
    expect(fieldText(tester, 'person-uscf-id'), '12641216');
    await tester.tap(find.byKey(const Key('person-save')));
    await tester.pumpAndSettle();
    expect(saved!.uscfId, '12641216');
    expect(saved!.rating, 2846);
  });

  testWidgets('a name is required; editing keeps the id', (tester) async {
    final existing = PersonRecord.create(name: 'Jane Doe', chesscom: 'janed');
    PersonRecord? saved;
    await pump(tester, (r) => saved = r, person: existing);
    await tester.enterText(find.byKey(const Key('person-name')), '');
    await tester.tap(find.byKey(const Key('person-save')));
    await tester.pumpAndSettle();
    expect(find.text('A name is needed.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('person-name')), 'Jane Roe');
    await tester.enterText(find.byKey(const Key('person-chesscom')), '');
    await tester.tap(find.byKey(const Key('person-save')));
    await tester.pumpAndSettle();
    expect(saved!.id, existing.id);
    expect(saved!.name, 'Jane Roe');
    expect(saved!.chesscom, isNull, reason: 'a cleared field is cleared');
  });
}
