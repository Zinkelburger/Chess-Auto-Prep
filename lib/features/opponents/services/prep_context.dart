/// What Player Analysis knows about the person it is analysing: which
/// directory record they are, and — when they were opened from a tournament —
/// which field, so the screen can offer their prep file and the next
/// opponent.
library;

import '../../../models/analysis_player_info.dart';
import '../models/person_record.dart';
import '../models/tournament.dart';
import 'opponent_store.dart';

class PrepContext {
  const PrepContext({required this.person, this.tournament, this.index});

  final PersonRecord person;
  final Tournament? tournament;

  /// Position in the tournament's field, 0-based; null without a tournament.
  final int? index;

  bool get inTournament => tournament != null;
  int get count => tournament?.entries.length ?? 0;

  TournamentEntry? get entry =>
      tournament == null || index == null ? null : tournament!.entries[index!];

  /// `Spring Open 2026 · 3 of 12`, or just the name outside a field.
  String get label =>
      tournament == null ? '' : '${tournament!.name} · ${index! + 1} of $count';

  /// The person [step] places along the field (+1 next, -1 previous), or
  /// null at either end.
  PersonRecord? neighbour(OpponentStore store, int step) {
    final t = tournament;
    final i = index;
    if (t == null || i == null) return null;
    final j = i + step;
    if (j < 0 || j >= t.entries.length) return null;
    return store.person(t.entries[j].personId);
  }

  /// Resolve the player Player Analysis holds to a directory person, and to
  /// a tournament when the game-set was opened from one (its `group` is the
  /// tournament's name). Null when the player is nobody in the directory.
  static PrepContext? resolve(OpponentStore store, AnalysisPlayerInfo player) {
    if (!store.isLoaded) return null;
    final person = store.personForPlayerName(player.username);
    if (person == null) return null;
    final group = player.group;
    final tournament = group == null ? null : store.tournamentNamed(group);
    if (tournament == null) return PrepContext(person: person);
    final index = tournament.indexOf(person.id);
    if (index < 0) return PrepContext(person: person);
    return PrepContext(person: person, tournament: tournament, index: index);
  }

  /// Re-read after the store changed (an entry ticked, a person edited).
  PrepContext? refresh(OpponentStore store) {
    final person = store.person(this.person.id);
    if (person == null) return null;
    final t = tournament == null ? null : store.tournament(tournament!.id);
    if (t == null) return PrepContext(person: person);
    final i = t.indexOf(person.id);
    return i < 0
        ? PrepContext(person: person)
        : PrepContext(person: person, tournament: t, index: i);
  }
}
