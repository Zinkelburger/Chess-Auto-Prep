import 'dart:convert';

import 'package:chess_auto_prep/features/opponents/services/uscf_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The US Chess API's shape as observed on 2026-09-04: upper-case names, a
/// `ratings` list keyed by system code, `items` for a name search.
void main() {
  const member = {
    'id': '12641216',
    'firstName': 'HIKARU',
    'lastName': 'NAKAMURA',
    'stateRep': 'NY',
    'status': 'Active',
    'ratings': [
      {'rating': 2846, 'ratingSystem': 'R', 'isProvisional': false},
      {'rating': 2723, 'ratingSystem': 'Q'},
      {'rating': 2910, 'ratingSystem': 'B'},
      {'rating': 2747, 'ratingSystem': 'OR', 'gamesPlayed': 21},
      {'ratingSystem': 'OQ', 'isProvisional': true},
    ],
  };

  UscfClient clientAnswering(Map<String, Object> routes) => UscfClient(
    client: MockClient((request) async {
      final key = '${request.url.path}?${request.url.query}';
      for (final entry in routes.entries) {
        if (key.contains(entry.key)) {
          return http.Response(jsonEncode(entry.value), 200);
        }
      }
      return http.Response('', 404);
    }),
  );

  test('member: id → title-cased name, ratings, state', () async {
    final client = clientAnswering({'/members/12641216': member});
    final m = await client.member(' 12641216 ');
    expect(m.id, '12641216');
    expect(m.name, 'Hikaru Nakamura');
    expect(m.regular, 2846);
    expect(m.quick, 2723);
    expect(m.blitz, 2910);
    expect(m.onlineRegular, 2747);
    expect(m.state, 'NY');
    expect(m.summary, '2846 · NY · Active');
  });

  test('member: a bad id is refused before any request', () async {
    final client = clientAnswering({});
    expect(() => client.member('123'), throwsA(isA<UscfException>()));
  });

  test('member: 404 becomes a plain sentence', () async {
    final client = clientAnswering({});
    expect(
      () => client.member('12345678'),
      throwsA(
        isA<UscfException>().having(
          (e) => e.message,
          'message',
          contains('no member'),
        ),
      ),
    );
  });

  test('search: name → members in the order given', () async {
    final client = clientAnswering({
      'name=nakamura': {
        'items': [
          member,
          {'id': '1', 'firstName': 'ANNA', 'lastName': "O'BRIEN-SMITH"},
        ],
      },
    });
    final found = await client.search('nakamura');
    expect(found.map((m) => m.name), ['Hikaru Nakamura', "Anna O'Brien-Smith"]);
    expect(found.last.rating, isNull);
  });

  test('search: too short a query asks nothing', () async {
    final client = clientAnswering({});
    expect(await client.search('a'), isEmpty);
  });

  test('titleCaseName keeps capitals after apostrophes and hyphens', () {
    expect(titleCaseName('JOHN MCDONALD'), 'John Mcdonald');
    expect(titleCaseName("o'brien"), "O'Brien");
    expect(titleCaseName('smith-jones'), 'Smith-Jones');
    expect(titleCaseName('J. R. R. TOLKIEN'), 'J. R. R. Tolkien');
  });
}
