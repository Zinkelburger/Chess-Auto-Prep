import 'package:chess_auto_prep/v2/chess/tournament/config.dart';
import 'package:chess_auto_prep/v2/chess/tournament/result.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/tournaments.dart';

final class ScriptedTournaments implements TournamentStore {
  final records = <String, Tournament>{};
  List<TournamentEngine> registry = [];
  @override
  Future<TournamentResult<List<Tournament>>> list() async =>
      TournamentSaved(records.values.toList());
  @override
  Future<TournamentResult<Tournament>> create(Tournament initial) async {
    records[initial.id] = initial;
    return TournamentSaved(initial);
  }

  @override
  Future<TournamentResult<Tournament>> save(
    Tournament before,
    Tournament after,
    String pgn, {
    required String? expectedPgn,
  }) async {
    records[after.id] = after;
    return TournamentSaved(after);
  }

  @override
  Future<TournamentResult<void>> remove(Tournament tournament) async {
    records.remove(tournament.id);
    return const TournamentSaved(null);
  }

  @override
  Future<TournamentResult<List<TournamentEngine>>> engines() async =>
      TournamentSaved(registry);
  @override
  Future<TournamentResult<void>> saveEngines(
    List<TournamentEngine> before,
    List<TournamentEngine> after,
  ) async {
    registry = after;
    return const TournamentSaved(null);
  }

  @override
  DocumentRef games(String id) =>
      DocumentRef('/test/engine_tournaments/$id/games.pgn');
}
