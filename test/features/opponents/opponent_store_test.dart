import 'dart:io';

import 'package:chess_auto_prep/features/opponents/models/person_record.dart';
import 'package:chess_auto_prep/features/opponents/models/tournament.dart';
import 'package:chess_auto_prep/features/opponents/services/opponent_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The directory and the tournaments are the user's own sheet, so what is
/// saved must come back exactly, people must be found by any key they were
/// entered under, and deleting a person must not leave a dangling row.
void main() {
  group('OpponentStore (memory)', () {
    late OpponentStore store;

    setUp(() async {
      store = OpponentStore(MemoryOpponentStorage());
      await store.ensureLoaded();
    });

    test('saves a person and finds them by every key', () async {
      final jane = await store.savePerson(
        PersonRecord.create(
          name: 'Jane Doe',
          uscfId: '12345678',
          chesscom: 'JaneD',
          lichess: 'jd_li',
          rating: 1850,
        ),
      );
      expect(store.people.single.id, jane.id);
      expect(store.matchPerson(uscfId: '12345678')?.id, jane.id);
      expect(store.matchPerson(chesscom: 'janed')?.id, jane.id);
      expect(store.matchPerson(lichess: 'JD_LI')?.id, jane.id);
      expect(store.matchPerson(name: 'jane doe')?.id, jane.id);
      expect(store.matchPerson(name: 'Someone Else'), isNull);
      expect(store.personForPlayerName('Jane Doe; JaneD; jd_li')?.id, jane.id);
    });

    test('search matches every word across name, id and handles', () async {
      await store.savePerson(
        PersonRecord.create(name: 'Jane Doe', chesscom: 'janed'),
      );
      await store.savePerson(PersonRecord.create(name: 'Bob Roe'));
      expect(store.searchPeople('doe').map((p) => p.name), ['Jane Doe']);
      expect(store.searchPeople('janed').map((p) => p.name), ['Jane Doe']);
      expect(store.searchPeople('jane roe'), isEmpty);
      expect(store.searchPeople('').length, 2);
    });

    test('tournaments carry entries and drop a deleted person', () async {
      final jane = await store.savePerson(PersonRecord.create(name: 'Jane'));
      final bob = await store.savePerson(PersonRecord.create(name: 'Bob'));
      var t = await store.createTournament('Spring Open 2026', rounds: 5);
      expect(t.id, 'spring-open-2026');
      t = await store.saveTournament(
        t
            .withEntry(TournamentEntry(personId: jane.id, rating: 1850))
            .withEntry(TournamentEntry(personId: bob.id)),
      );
      expect(t.entries.length, 2);
      expect(store.tournamentCountFor(jane.id), 1);

      await store.deletePerson(jane.id);
      expect(store.tournament(t.id)!.entries.map((e) => e.personId), [bob.id]);
      expect(store.people.map((p) => p.name), ['Bob']);
    });

    test('a second tournament with the same name gets its own id', () async {
      final a = await store.createTournament('Club Championship');
      final b = await store.createTournament('Club Championship');
      expect(a.id, 'club-championship');
      expect(b.id, 'club-championship-2');
      expect(store.tournamentNamed('club championship')?.id, a.id);
    });

    test('withEntry replaces an existing row and keeps the tick', () async {
      final jane = await store.savePerson(PersonRecord.create(name: 'Jane'));
      var t = await store.createTournament('Open');
      t = t.withEntry(
        TournamentEntry(personId: jane.id, rating: 1800, prepared: true),
      );
      t = t.withEntry(t.entries.single.copyWith(rating: 1900));
      expect(t.entries.single.rating, 1900);
      expect(t.entries.single.prepared, isTrue);
    });
  });

  group('OpponentStore (files)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('opponents-store-');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('round-trips people and tournaments through disk', () async {
      final storage = FileOpponentStorage(root: () async => dir);
      final store = OpponentStore(storage);
      await store.ensureLoaded();
      final jane = await store.savePerson(
        PersonRecord.create(
          name: 'Jane Doe',
          uscfId: '12345678',
          chesscom: 'janed',
          notes: 'Plays the London.\nAvoids sharp lines.',
        ),
      );
      final t = await store.saveTournament(
        (await store.createTournament(
          'Spring Open 2026',
          date: '2026-04-12',
        )).withEntry(
          TournamentEntry(
            personId: jane.id,
            rating: 1850,
            pairingProb: 0.42,
            likelyRound: 2,
            prepared: true,
          ),
        ),
      );

      expect(await File('${dir.path}/people.json').exists(), isTrue);
      expect(
        await File('${dir.path}/tournaments/${t.id}.json').exists(),
        isTrue,
      );

      final again = OpponentStore(FileOpponentStorage(root: () async => dir));
      await again.ensureLoaded();
      final p = again.people.single;
      expect(p.id, jane.id);
      expect(p.uscfId, '12345678');
      expect(p.chesscom, 'janed');
      expect(p.notes, 'Plays the London.\nAvoids sharp lines.');
      final loaded = again.tournament(t.id)!;
      expect(loaded.name, 'Spring Open 2026');
      expect(loaded.date, '2026-04-12');
      final e = loaded.entries.single;
      expect(e.personId, jane.id);
      expect(e.rating, 1850);
      expect(e.pairingProb, 0.42);
      expect(e.likelyRound, 2);
      expect(e.prepared, isTrue);
    });

    test('a corrupt tournament file is skipped, not fatal', () async {
      await Directory('${dir.path}/tournaments').create(recursive: true);
      await File('${dir.path}/tournaments/bad.json').writeAsString('{nope');
      final store = OpponentStore(FileOpponentStorage(root: () async => dir));
      await store.ensureLoaded();
      expect(store.tournaments, isEmpty);
      expect(store.isLoaded, isTrue);
    });
  });
}
