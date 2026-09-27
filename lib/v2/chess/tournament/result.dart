import 'config.dart';
import 'standings.dart';

/// Names and keys are the existing tournament.json protocol. PGNs remain
/// separate ordinary documents; records address them by schedule order.
final class TournamentGame {
  TournamentGame(Map<String, Object?> data) : json = tournamentSnapshot(data);
  final Map<String, Object?> json;
  int get index => tournamentInt(json, 'gameIndex', 0);
  int get white => tournamentInt(json, 'whiteIndex', 0);
  int get black => tournamentInt(json, 'blackIndex', 1);
  String get whiteName => json['whiteName'] as String? ?? 'White';
  String get blackName => json['blackName'] as String? ?? 'Black';
  String get termination => json['termination'] as String? ?? 'aborted';
  String get detail => json['detail'] as String? ?? '';
  String get result => switch (json['result']) {
    'whiteWins' => '1-0',
    'blackWins' => '0-1',
    'draw' => '1/2-1/2',
    _ => '*',
  };
}

final class Tournament {
  Tournament(Map<String, Object?> data)
    : json = tournamentSnapshot(data),
      config = TournamentConfig(tournamentObject(data['config'])),
      games = List.unmodifiable([
        for (final game in data['games'] as List? ?? const [])
          TournamentGame(tournamentObject(game)),
      ]);
  final Map<String, Object?> json;
  final TournamentConfig config;
  final List<TournamentGame> games;
  String get id => json['id'] as String? ?? '';
  String get status => json['status'] as String? ?? 'pending';
  String? get error => json['error'] as String?;
  Tournament changed(Map<String, Object?> values) =>
      Tournament({...json, ...values});

  late final List<TournamentStanding> standings = tournamentStandings(this);

  late final List<TournamentScore> scores = _scores();

  List<TournamentScore> _scores() {
    final seeded = [...standings]..sort((a, b) => a.seat.compareTo(b.seat));
    return List.unmodifiable([
      for (final row in seeded)
        TournamentScore(
          row.name,
          row.score.wins,
          row.score.draws,
          row.score.losses,
        ),
    ]);
  }
}

/// A derived table row. Unfinished games award neither side points.
final class TournamentScore {
  const TournamentScore(this.name, this.wins, this.draws, this.losses);
  final String name;
  final int wins;
  final int draws;
  final int losses;
  double get points => wins + draws / 2;
}
