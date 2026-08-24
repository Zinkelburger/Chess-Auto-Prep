import 'package:chess_auto_prep/features/engine_tournament/models/engine_spec.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/stored_tournament.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/tournament_config.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/tournament_game.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/tournament_summary.dart';
import 'package:flutter_test/flutter_test.dart';

EngineSpec _engine(String name) =>
    EngineSpec(id: name.toLowerCase(), name: name, executablePath: '/bin/x');

TournamentConfig _config(List<String> names, {int gamesPerPairing = 10}) =>
    TournamentConfig(
      name: 'Match',
      engines: [for (final n in names) _engine(n)],
      gamesPerPairing: gamesPerPairing,
    );

TournamentGameRecord _game({
  required int index,
  required int white,
  required int black,
  required GameResult result,
}) => TournamentGameRecord(
  gameIndex: index,
  round: 1,
  whiteIndex: white,
  blackIndex: black,
  whiteName: 'w',
  blackName: 'b',
  result: result,
  termination: TerminationReason.checkmate,
  plies: 40,
  startedAt: DateTime(2026, 8, 22),
  durationMs: 1000,
);

StoredTournament _stored({
  required TournamentConfig config,
  required List<TournamentGameRecord> games,
  TournamentStatus status = TournamentStatus.completed,
  DateTime? createdAt,
  DateTime? finishedAt,
}) => StoredTournament(
  id: 'match',
  directoryPath: '/tmp/match',
  pgnPath: '/tmp/match/games.pgn',
  config: config,
  createdAt: createdAt ?? DateTime(2026, 8, 22, 17, 30),
  status: status,
  games: games,
  finishedAt: finishedAt,
);

void main() {
  group('formatMatchPoints', () {
    test('writes halves the way a match score is written', () {
      expect(formatMatchPoints(5.5), '5½');
      expect(formatMatchPoints(5), '5');
      expect(formatMatchPoints(0.5), '½');
      expect(formatMatchPoints(0), '0');
    });
  });

  group('engineDisplayNames', () {
    test('numbers an engine that plays itself', () {
      expect(engineDisplayNames(_config(['Stockfish', 'Stockfish'])), [
        'Stockfish #1',
        'Stockfish #2',
      ]);
    });

    test('leaves distinct names alone', () {
      expect(engineDisplayNames(_config(['Alpha', 'Beta'])), ['Alpha', 'Beta']);
    });
  });

  group('tournamentOutcome', () {
    test('a match reads as a score, in seeding order', () {
      final config = _config(['Alpha', 'Beta']);
      final outcome = tournamentOutcome(
        _stored(
          config: config,
          games: [
            _game(index: 0, white: 0, black: 1, result: GameResult.whiteWins),
            _game(index: 1, white: 1, black: 0, result: GameResult.draw),
          ],
        ),
      );
      expect(outcome!.label, 'Alpha 1½–½ Beta');
      expect(outcome.leader, 'Alpha');
    });

    test('a level match names nobody', () {
      final config = _config(['Alpha', 'Beta']);
      final outcome = tournamentOutcome(
        _stored(
          config: config,
          games: [
            _game(index: 0, white: 0, black: 1, result: GameResult.draw),
            _game(index: 1, white: 1, black: 0, result: GameResult.draw),
          ],
        ),
      );
      expect(outcome!.label, 'Alpha 1–1 Beta');
      expect(outcome.leader, isNull);
      expect(outcome.isDecided, false);
    });

    test('a field reports its leader, and says so while still running', () {
      final config = _config(['Alpha', 'Beta', 'Gamma']);
      final games = [
        _game(index: 0, white: 0, black: 1, result: GameResult.whiteWins),
        _game(index: 1, white: 0, black: 2, result: GameResult.whiteWins),
        _game(index: 2, white: 1, black: 2, result: GameResult.draw),
      ];
      expect(
        tournamentOutcome(_stored(config: config, games: games))!.label,
        'Alpha won with 2/2',
      );
      expect(
        tournamentOutcome(
          _stored(
            config: config,
            games: games,
            status: TournamentStatus.running,
          ),
        )!.label,
        'Alpha leads on 2/2',
      );
    });

    test('a run with no games yet has nothing to report', () {
      expect(
        tournamentOutcome(
          _stored(config: _config(['Alpha', 'Beta']), games: []),
        ),
        isNull,
      );
    });
  });

  group('history labels', () {
    final now = DateTime(2026, 8, 22, 20, 0);

    test('recent runs group under Today and Yesterday', () {
      expect(tournamentDayGroup(DateTime(2026, 8, 22, 1), now: now), 'Today');
      expect(
        tournamentDayGroup(DateTime(2026, 8, 21, 23), now: now),
        'Yesterday',
      );
      expect(
        tournamentDayGroup(DateTime(2026, 8, 20), now: now),
        'August 2026',
      );
      expect(tournamentDayGroup(DateTime(2026, 7, 2), now: now), 'July 2026');
    });

    test('the timestamp is a clock time only while it still means one', () {
      expect(
        tournamentTimeLabel(DateTime(2026, 8, 22, 17, 5), now: now),
        '17:05',
      );
      expect(
        tournamentTimeLabel(DateTime(2026, 8, 21, 9, 0), now: now),
        '09:00',
      );
      expect(
        tournamentTimeLabel(DateTime(2026, 8, 19, 9, 0), now: now),
        'Aug 19',
      );
    });

    test('run durations stay short', () {
      expect(formatRunDuration(const Duration(seconds: 38)), '38s');
      expect(
        formatRunDuration(const Duration(minutes: 4, seconds: 9)),
        '4m 09s',
      );
      expect(
        formatRunDuration(const Duration(hours: 1, minutes: 12)),
        '1h 12m',
      );
    });
  });
}
