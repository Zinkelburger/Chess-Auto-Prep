import '../../chess/tournament/config.dart';
import 'game_runner.dart';

/// Plays a run's pairings, [TournamentConfig.concurrency] games at a time,
/// and keeps the finished games in schedule order. The app's
/// `TournamentRun` and `tools/run_engine_tournament.dart` both play through
/// one; each saves its checkpoints its own way.
final class TournamentSchedule {
  TournamentSchedule(this.config, this.launch);

  final TournamentConfig config;
  final TournamentLauncher launch;
  final _completed = <int, PlayedGame>{};
  Future<void> _saving = Future.value();

  /// Plays until every pairing has been played or [stopping] says so. After
  /// each game [afterGame] runs, one at a time in finishing order, before
  /// that game's worker starts another.
  Future<void> play({
    required bool Function() stopping,
    required Future<void> Function(Pairing pairing, PlayedGame game) afterGame,
    void Function(LiveGame position)? onPosition,
  }) async {
    final schedule = config.schedule;
    var next = 0;
    Future<void> worker() async {
      while (!stopping() && next < schedule.length) {
        final pairing = schedule[next++];
        final game = await TournamentGameRunner(
          config: config,
          pairing: pairing,
          launch: launch,
          stopping: stopping,
          onPosition: onPosition ?? (_) {},
        ).play();
        _completed[pairing.index] = game;
        _saving = _saving.then((_) => afterGame(pairing, game));
        await _saving;
      }
    }

    await Future.wait([for (var i = 0; i < config.concurrency; i++) worker()]);
  }

  /// The games finished so far in schedule order, numbered as they are
  /// saved, and their PGN.
  ({List<Map<String, Object?>> records, String pgn}) get finished {
    final records = <Map<String, Object?>>[];
    final texts = <String>[];
    for (final key in _completed.keys.toList()..sort()) {
      final game = _completed[key]!;
      records.add({...game.record.json, 'gameIndex': records.length});
      texts.add(game.pgn);
    }
    return (records: records, pgn: texts.join('\n'));
  }
}
