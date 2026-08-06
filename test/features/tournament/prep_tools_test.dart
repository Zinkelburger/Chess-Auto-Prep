/// The chess half of the agent tool surface.
///
/// Identity and roster editing moved to the standalone server and are covered
/// by `tools/mcp/test_chess_prep.py`; what remains here is what genuinely
/// needs the app. The roster is set up directly on the session, which is also
/// how it arrives in production — written to the shared file by the
/// standalone server and loaded by [TournamentSession].
library;

import 'package:chess_auto_prep/features/tournament/mcp/prep_tools.dart';
import 'package:chess_auto_prep/features/tournament/models/roster_entry.dart';
import 'package:chess_auto_prep/features/tournament/services/tournament_session.dart';
import 'package:flutter_test/flutter_test.dart';

late TournamentSession session;
late PrepToolRegistry registry;

Roster _field(int count, {int rounds = 4, bool withMe = true}) => Roster(
  eventName: 'Spring Open',
  rounds: rounds,
  entries: [
    for (var i = 0; i < count; i++)
      RosterEntry(
        id: 'p$i',
        name: 'Player $i',
        uscfId: '1000000$i',
        rating: 2100 - i * 50,
      ),
    RosterEntry(
      id: 'me',
      name: 'Me, Myself',
      uscfId: '55556666',
      rating: 1900,
      isMe: withMe,
    ),
  ],
);

Future<Map<String, dynamic>> call(
  String name, [
  Map<String, dynamic> args = const {},
]) => registry.callEncoded(name, args);

Future<Map<String, dynamic>> callOk(
  String name, [
  Map<String, dynamic> args = const {},
]) async {
  final result = await call(name, args);
  expect(result['ok'], isTrue, reason: 'tool $name failed: ${result['error']}');
  return (result['result'] as Map).cast<String, dynamic>();
}

void main() {
  setUp(() {
    session = TournamentSession();
    registry = PrepToolRegistry(session);
  });

  test('exposes only tools that genuinely need the app', () {
    final names = registry.tools.map((t) => t.name).toSet();
    expect(names, {
      'roster_get',
      'pairing_simulate',
      'repertoire_list',
      'prep_run',
      'prep_export',
    });

    // Identity work must not be reachable here — it lives in the standalone
    // server so an agent can do it with the app shut.
    expect(names, isNot(contains('identity_propose')));
    expect(names, isNot(contains('directory_search')));
    expect(names, isNot(contains('roster_import')));
  });

  test('every tool has a name, description and object schema', () {
    for (final tool in registry.tools) {
      expect(tool.name, isNotEmpty);
      expect(
        tool.description.length,
        greaterThan(40),
        reason: '${tool.name} needs a description an agent can act on',
      );
      expect(tool.inputSchema['type'], 'object');
      expect(tool.inputSchema['properties'], isA<Map>());
    }
    final names = registry.tools.map((t) => t.name).toList();
    expect(names.toSet().length, names.length);
  });

  test('unknown tools fail cleanly rather than throwing', () async {
    final result = await call('no_such_tool');
    expect(result['ok'], isFalse);
    expect(result['error'], contains('Unknown tool'));
  });

  test('roster_get reflects whatever the shared session holds', () async {
    session.setRoster(_field(3));
    final roster = await callOk('roster_get');

    expect(roster['event_name'], 'Spring Open');
    expect((roster['entries'] as List), hasLength(4));
  });

  group('pairing_simulate', () {
    test('needs a reference player', () async {
      session.setRoster(_field(3, withMe: false));
      final result = await call('pairing_simulate', {'trials': 50});
      expect(result['ok'], isFalse);
      expect(result['error'], contains('marked as you'));
    });

    test('returns per-opponent probabilities with names attached', () async {
      session.setRoster(_field(7));
      final r = await callOk('pairing_simulate', {'trials': 200, 'seed': 7});

      final opponents = (r['opponents'] as List).cast<Map>();
      expect(opponents, isNotEmpty);
      for (final o in opponents) {
        expect(o['name'], isNotNull);
        expect(o['prob_any'], isA<num>());
        expect(o['prob_as_white'], isA<num>());
        expect(o['prob_as_black'], isA<num>());
      }
      expect(r['rounds'], 4);
    });

    test('honors a withhold recorded on the roster', () async {
      // Constraints arrive on the roster from the standalone server; the
      // simulator must act on them wherever they came from.
      session.setRoster(_field(11));
      final baseline = await callOk('pairing_simulate', {
        'trials': 300,
        'seed': 3,
      });
      final blockedId =
          (baseline['opponents'] as List).cast<Map>().firstWhere(
                (o) => (o['prob_by_round'] as List)[0] as num > 0.9,
              )['player']
              as String;

      session.addConstraint('me', blockedId, reason: 'siblings');
      final r = await callOk('pairing_simulate', {'trials': 300, 'seed': 3});

      final blocked = (r['opponents'] as List).cast<Map>().where(
        (o) => o['player'] == blockedId,
      );
      expect(
        blocked.isEmpty || (blocked.first['prob_any'] as num) < 0.05,
        isTrue,
        reason: 'a forbidden pairing should be routed around',
      );
    });
  });

  group('prep', () {
    test('prep_run requires a repertoire', () async {
      session.setRoster(_field(3));
      final result = await call('prep_run');
      expect(result['ok'], isFalse);
      expect(result['error'], contains('repertoire'));
    });

    test('prep_run requires a reference player', () async {
      session.setRoster(_field(3, withMe: false));
      final result = await call('prep_run', {
        'white_repertoire_path': '/tmp/does-not-matter.pgn',
      });
      expect(result['ok'], isFalse);
      expect(result['error'], contains('marked as you'));
    });

    test('prep_export refuses before a run', () async {
      session.setRoster(_field(3));
      final result = await call('prep_export', {'format': 'pgn'});
      expect(result['ok'], isFalse);
      expect(result['error'], contains('prep_run'));
    });

    test('prep_export rejects an unknown format', () async {
      session.setRoster(_field(3));
      final result = await call('prep_export', {'format': 'roster_csv'});
      expect(result['ok'], isFalse);
      // Roster CSV moved to the standalone server.
      expect(result['error'], isNotNull);
    });

    test('repertoire_list answers even with nothing installed', () async {
      final r = await callOk('repertoire_list');
      expect(r['repertoires'], isA<List>());
    });
  });
}
