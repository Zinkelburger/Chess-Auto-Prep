import 'package:chess_auto_prep/features/opponents/models/person_record.dart';
import 'package:chess_auto_prep/features/opponents/services/opponent_store.dart';
import 'package:chess_auto_prep/features/opponents/services/tournament_import.dart';
import 'package:flutter_test/flutter_test.dart';

/// Importing an opponents.json must reuse the people already in the
/// directory (by USCF ID, handle, or name), fill only their blanks, keep
/// entrants with no online account, and never duplicate a row.
void main() {
  late OpponentStore store;

  setUp(() async {
    store = OpponentStore(MemoryOpponentStorage());
    await store.ensureLoaded();
  });

  const list = '''
{
  "format": "chess-auto-prep/opponents@1",
  "event": "Spring Open 2026",
  "opponents": [
    {"name": "Jane Doe", "uscf_id": "12345678", "chesscom": "janed",
     "rating": 1850, "pairing_prob": 0.42, "most_likely_round": 2},
    {"name": "Bob Roe", "lichess": "bobr", "rating": 1700},
    {"name": "Offline Only", "uscf_id": "99999999", "rating": 1600}
  ]
}
''';

  test('creates the tournament and everyone in it', () async {
    final result = await TournamentImport(store).importText(list);
    expect(result.tournament.name, 'Spring Open 2026');
    expect(result.added, 3);
    expect(result.newPeople, 3);
    expect(store.people.map((p) => p.name), [
      'Bob Roe',
      'Jane Doe',
      'Offline Only',
    ]);
    final jane = store.matchPerson(uscfId: '12345678')!;
    final entry = result.tournament.entries.firstWhere(
      (e) => e.personId == jane.id,
    );
    expect(entry.pairingProb, 0.42);
    expect(entry.likelyRound, 2);
    expect(entry.rating, 1850);
    expect(store.matchPerson(name: 'Offline Only')!.hasAccount, isFalse);
  });

  test('matches an existing person and fills only their blanks', () async {
    final jane = await store.savePerson(
      PersonRecord.create(name: 'J. Doe', uscfId: '12345678', rating: 1900),
    );
    final result = await TournamentImport(store).importText(list);
    expect(result.newPeople, 2);
    final again = store.person(jane.id)!;
    expect(again.name, 'J. Doe', reason: 'the user\'s spelling wins');
    expect(again.rating, 1900, reason: 'an existing rating is kept');
    expect(again.chesscom, 'janed', reason: 'a blank handle is filled');
  });

  test('importing twice refreshes odds without duplicating rows', () async {
    final first = await TournamentImport(store).importText(list);
    var t = first.tournament;
    t = await store.saveTournament(
      t.withEntry(t.entries.first.copyWith(prepared: true)),
    );
    final second = await TournamentImport(
      store,
    ).importText(list.replaceAll('0.42', '0.55'), tournament: t);
    expect(second.added, 0);
    expect(second.alreadyListed, 3);
    expect(second.tournament.entries.length, 3);
    expect(second.tournament.entries.first.prepared, isTrue);
    expect(second.tournament.entries.first.pairingProb, 0.55);
  });
}
