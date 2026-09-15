/// What Player Analysis knows about the person it is analysing: which
/// directory record they are, and — when they were opened from a tournament —
/// which field and where in it.
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

  /// Resolve the player Player Analysis holds to a directory person, and to
  /// a tournament when the game-set was opened from one (its `group` is the
  /// tournament's name). Null when the player is nobody in the directory.
  static PrepContext? resolve(OpponentStore store, AnalysisPlayerInfo player) {
    if (!store.isLoaded) return null;
    final person = store.personForPlayer(player);
    if (person == null) return null;
    final group = player.group;
    final tournament = group == null ? null : store.tournamentNamed(group);
    final index = tournament?.indexOf(person.id) ?? -1;
    if (tournament == null || index < 0) return PrepContext(person: person);
    return PrepContext(person: person, tournament: tournament, index: index);
  }
}
