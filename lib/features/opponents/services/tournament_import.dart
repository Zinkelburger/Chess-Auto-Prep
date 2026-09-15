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

  static const _defaultTournamentName = 'Imported field';

  /// Parse [text] and merge it into [tournament] (created when null, named
  /// after the list's event).
  Future<TournamentImportResult> importText(
    String text, {
    Tournament? tournament,
  }) => importList(
    OpponentList.parse(text, keepAccountless: true),
    tournament: tournament,
  );

  Future<TournamentImportResult> importList(
    OpponentList list, {
    Tournament? tournament,
  }) async {
    await store.ensureLoaded();
    var target =
        tournament ??
        await store.createTournament(list.event ?? _defaultTournamentName);

    var added = 0;
    var alreadyListed = 0;
    var newPeople = 0;
    for (final row in list.opponents) {
      final (:person, :created) = await _mergePerson(row);
      if (created) newPeople++;
      final existingIndex = target.indexOf(person.id);
      if (existingIndex >= 0) {
        alreadyListed++;
      } else {
        added++;
      }
      target = target.withEntry(
        TournamentEntry(
          personId: person.id,
          rating: row.rating ?? person.rating,
          pairingProb: row.pairingProb,
          likelyRound: row.mostLikelyRound,
          prepared:
              existingIndex >= 0 && target.entries[existingIndex].prepared,
        ),
      );
    }
    target = await store.saveTournament(target);
    return TournamentImportResult(
      tournament: target,
      added: added,
      alreadyListed: alreadyListed,
      newPeople: newPeople,
      warnings: list.warnings,
    );
  }

  /// Merge a directory row without creating a tournament or group.
  /// Existing user-entered values win; imports only fill missing fields.
  Future<PersonRecord> importPerson(OpponentEntry row) async {
    await store.ensureLoaded();
    return (await _mergePerson(row)).person;
  }

  /// The directory person for [row], created when nobody matches.
  Future<({PersonRecord person, bool created})> _mergePerson(
    OpponentEntry row,
  ) async {
    final match = store.matchPerson(
      uscfId: row.uscfId,
      chesscom: row.chesscom,
      lichess: row.lichess,
      name: row.name,
    );
    if (match == null) {
      final person = await store.savePerson(
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
      return (person: person, created: true);
    }
    // Fill blanks only: the directory is the user's, the list is advice.
    final fillsBlank =
        (match.uscfId == null && row.uscfId != null) ||
        (match.chesscom == null && row.chesscom != null) ||
        (match.lichess == null && row.lichess != null) ||
        (match.rating == null && row.rating != null) ||
        (match.title == null && row.title != null);
    if (!fillsBlank) return (person: match, created: false);
    final filled = await store.savePerson(
      match.copyWith(
        uscfId: match.uscfId ?? row.uscfId,
        chesscom: match.chesscom ?? row.chesscom,
        lichess: match.lichess ?? row.lichess,
        rating: match.rating ?? row.rating,
        title: match.title ?? row.title,
      ),
    );
    return (person: filled, created: false);
  }
}
