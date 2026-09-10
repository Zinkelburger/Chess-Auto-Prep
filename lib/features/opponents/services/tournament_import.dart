/// Turning an opponent list (`chess-auto-prep/opponents@1`, written by the
/// MCP server's `opponents_export` or by hand) into a tournament's field.
///
/// Every row becomes a person in the directory — matched to an existing one
/// by USCF ID, then online handle, then exact name, so importing the same
/// event twice or two events with the same regular never duplicates anyone —
/// and an entry in the tournament carrying the row's rating and pairing odds.
library;

import '../../../services/opponent_list.dart';
import '../models/person_record.dart';
import '../models/tournament.dart';
import 'opponent_store.dart';

class TournamentImportResult {
  const TournamentImportResult({
    required this.tournament,
    required this.added,
    required this.alreadyListed,
    required this.newPeople,
    required this.warnings,
  });

  final Tournament tournament;

  /// Entries added to the field.
  final int added;

  /// Rows whose person was already in this field (their odds were refreshed).
  final int alreadyListed;

  /// People created in the directory because nobody matched.
  final int newPeople;
  final List<String> warnings;

  String get summary => [
    'Added $added',
    if (alreadyListed > 0) '$alreadyListed already listed',
    if (newPeople > 0) '$newPeople new in the directory',
    if (warnings.isNotEmpty) '${warnings.length} skipped',
  ].join(' · ');
}

class TournamentImport {
  TournamentImport(this.store);

  final OpponentStore store;

  /// Parse [text] and merge it into [tournament] (created when null, named
  /// after the list's event).
  Future<TournamentImportResult> importText(
    String text, {
    Tournament? tournament,
  }) async {
    final list = OpponentList.parse(text, keepAccountless: true);
    return importList(list, tournament: tournament);
  }

  Future<TournamentImportResult> importList(
    OpponentList list, {
    Tournament? tournament,
  }) async {
    await store.ensureLoaded();
    var target =
        tournament ??
        await store.createTournament(list.event ?? 'Imported field');

    var added = 0;
    var already = 0;
    var newPeople = 0;
    for (final row in list.opponents) {
      final before = store.people.length;
      final person = await importPerson(row);
      if (store.people.length > before) newPeople++;
      final existing = target.indexOf(person.id);
      final entry = TournamentEntry(
        personId: person.id,
        rating: row.rating ?? person.rating,
        pairingProb: row.pairingProb,
        likelyRound: row.mostLikelyRound,
        prepared: existing >= 0 && target.entries[existing].prepared,
      );
      if (existing >= 0) {
        already++;
      } else {
        added++;
      }
      target = target.withEntry(entry);
    }
    target = await store.saveTournament(target);
    return TournamentImportResult(
      tournament: target,
      added: added,
      alreadyListed: already,
      newPeople: newPeople,
      warnings: list.warnings,
    );
  }

  /// Merge a directory row without creating a tournament or group.
  /// Existing user-entered values win; imports only fill missing fields.
  Future<PersonRecord> importPerson(OpponentEntry row) async {
    await store.ensureLoaded();
    var person = store.matchPerson(
      uscfId: row.uscfId,
      chesscom: row.chesscom,
      lichess: row.lichess,
      name: row.name,
    );
    if (person == null) {
      person = await store.savePerson(
        PersonRecord.create(
          name: row.name,
          uscfId: row.uscfId,
          chesscom: row.chesscom,
          lichess: row.lichess,
          rating: row.rating,
          title: row.title,
          notes: row.note ?? '',
        ),
      );
    } else {
      // Fill blanks only: the directory is the user's, the list is advice.
      final filled = person.copyWith(
        uscfId: person.uscfId ?? row.uscfId,
        chesscom: person.chesscom ?? row.chesscom,
        lichess: person.lichess ?? row.lichess,
        rating: person.rating ?? row.rating,
        title: person.title ?? row.title,
      );
      if (filled.uscfId != person.uscfId ||
          filled.chesscom != person.chesscom ||
          filled.lichess != person.lichess ||
          filled.rating != person.rating ||
          filled.title != person.title) {
        person = await store.savePerson(filled);
      }
    }

    return person;
  }
}
