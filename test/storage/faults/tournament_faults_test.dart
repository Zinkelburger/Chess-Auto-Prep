// Engine tournaments written under a fault at every effect: a game's results
// saved as its games.pgn and its tournament.json together
// (`FileTournaments.save`, journaled in `.v2-pending.json`), a tournament
// created, and an engine registered in `engines.json`. After any fault each
// reads as before the command or after it, never with the game in one file
// and not the other, and the other records read as they did. A failed
// command is retried with the same inputs. See fault_matrix.dart for the
// families.
@TestOn('linux')
// Every case runs a fault matrix of isolates: four times the default
// 30 s, for a busy CI runner.
@Timeout.factor(4)
library;

import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/chess/tournament/result.dart';
import 'package:chess_auto_prep/storage/tournaments.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/faulty_disk/contracts.dart';
import '../../support/faulty_disk/fault_matrix.dart';
import '../../support/faulty_disk/record_stores.dart';
import '../../support/faulty_disk/scenario.dart';

const _pgnAfter =
    '$seededTournamentPgn\n'
    '[Event "Match"]\n[Round "2"]\n[Result "0-1"]\n\n1. f3 e5 2. g4 Qh4# 0-1\n';

/// The second game, played and saved with the first.
Future<TournamentResult<Tournament>> _save(RecordStores s) {
  final before = seededTournament();
  final after = before.changed({
    'status': 'completed',
    'games': [
      for (final game in before.games) game.json,
      {'whiteIndex': 1, 'blackIndex': 0, 'result': '0-1'},
    ],
  });
  return s.tournaments.save(
    before,
    after,
    _pgnAfter,
    expectedPgn: seededTournamentPgn,
  );
}

/// Saved, or refused because another window changed it; anything else is
/// a save that may have landed, which the runner retries.
Verdict _saved(TournamentResult<Tournament> result) => switch (result) {
  TournamentSaved() => Verdict.committed,
  TournamentFailed(:final message) when message.contains('another window') =>
    Verdict.rejected,
  TournamentFailed() => Verdict.unknown,
};

Future<String> _tournaments(RecordStores s) => s.tournamentsNow();

/// A second tournament, not started.
Future<TournamentResult<Tournament>> _create(RecordStores s) =>
    s.tournaments.create(
      seededTournament().changed({
        'id': 'rematch',
        'status': 'pending',
        'games': const <Object>[],
      }),
    );

/// The bundled engine, registered on a profile with no registry yet.
Future<TournamentResult<void>> _register(RecordStores s) =>
    s.tournaments.saveEngines(const [], [TournamentEngine.bundled()]);

Verdict _done(TournamentResult<Object?> result) => switch (result) {
  TournamentSaved() => Verdict.committed,
  TournamentFailed() => Verdict.unknown,
};

/// The engines the registry lists, or why it could not.
Future<String> _engines(RecordStores s) async =>
    switch (await s.tournaments.engines()) {
      TournamentSaved(:final value, :final warnings) => [
        for (final engine in value) engine.name,
        ...warnings,
      ].join('; '),
      TournamentFailed(:final message) => 'failed $message',
    };

const _results = StorageScenario<RecordStores, TournamentResult<Tournament>>(
  name: 'save tournament results',
  seed: seedRecordProfile,
  open: RecordStores.open,
  command: _save,
  verdict: _saved,
  retry: _save,
  firstRead: _tournaments,
  probes: recordProbes,
);

const _created = StorageScenario<RecordStores, TournamentResult<Tournament>>(
  name: 'create a tournament',
  seed: seedRecordProfile,
  open: RecordStores.open,
  command: _create,
  verdict: _done,
  retry: _create,
  firstRead: _tournaments,
  probes: recordProbes,
);

const _registered = StorageScenario<RecordStores, TournamentResult<void>>(
  name: 'register an engine',
  seed: seedRecordProfile,
  open: RecordStores.open,
  command: _register,
  verdict: _done,
  retry: _register,
  firstRead: _engines,
  probes: recordProbes,
);

void main() {
  faultMatrix(_results);
  faultMatrix(_created);
  faultMatrix(_registered);
}
