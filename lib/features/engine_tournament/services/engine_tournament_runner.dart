/// Runs a whole tournament: builds the schedule, keeps the engine processes
/// alive across games, and persists after every result.
///
/// Persisting per game (rather than at the end) is what makes a long match
/// survivable — close the app, kill the process, lose power, and the games
/// already played are still on disk and still open in the viewer.
///
/// Pure `dart:io`, so `tools/run_engine_tournament.dart` runs the identical
/// code path the app runs.
library;

import 'dart:async';

import '../models/engine_spec.dart';
import '../models/stored_tournament.dart';
import '../models/tournament_config.dart';
import '../models/tournament_game.dart';
import 'engine_game_runner.dart';
import 'tournament_store.dart';
import 'uci_engine.dart';

/// One slot in the schedule, before it is played.
class ScheduledGame {
  const ScheduledGame({
    required this.index,
    required this.round,
    required this.whiteIndex,
    required this.blackIndex,
  });

  final int index;
  final int round;
  final int whiteIndex;
  final int blackIndex;
}

/// Round-major order: every pairing plays its first game before any pairing
/// plays its second, so a tournament stopped halfway is still balanced.
List<ScheduledGame> buildSchedule(TournamentConfig config) {
  final pairings = config.pairings;
  final schedule = <ScheduledGame>[];
  var index = 0;
  for (var round = 1; round <= config.gamesPerPairing; round++) {
    for (final pairing in pairings) {
      final swap = config.alternateColors && round.isEven;
      schedule.add(
        ScheduledGame(
          index: index++,
          round: round,
          whiteIndex: swap ? pairing.b : pairing.a,
          blackIndex: swap ? pairing.a : pairing.b,
        ),
      );
    }
  }
  return schedule;
}

/// Resolves an [EngineSpec] to a binary on disk. The bundled entry has no
/// stored path — the app extracts it at runtime — so this is injected.
typedef ExecutableResolver = Future<String> Function(EngineSpec spec);

class EngineTournamentRunner {
  EngineTournamentRunner({
    required this.store,
    required this.resolveExecutable,
    this.onLog,
  });

  final TournamentStore store;
  final ExecutableResolver resolveExecutable;
  final void Function(String message)? onLog;

  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  /// Stop after the games currently in flight finish their current move.
  void cancel() => _cancelled = true;

  /// Play [tournament] to completion (or until [cancel]).
  ///
  /// Returns the final stored state; [onUpdate] fires after every game with
  /// the same object that was just written to disk.
  Future<StoredTournament> run(
    StoredTournament tournament, {
    void Function(StoredTournament state)? onUpdate,
    void Function(ScheduledGame slot, GameMoveEvent move)? onMove,
    void Function(ScheduledGame slot)? onGameStarted,
    void Function(ScheduledGame slot, PlayedGame game)? onGameFinished,
  }) async {
    final config = tournament.config;
    if (config.engines.length < 2) {
      return _fail(tournament, 'A tournament needs at least two engines.');
    }

    final schedule = buildSchedule(config);
    if (schedule.isEmpty) {
      return _fail(tournament, 'The schedule is empty — nothing to play.');
    }

    var state = tournament.copyWith(
      status: TournamentStatus.running,
      games: const [],
      error: null,
    );
    await store.save(state);
    onUpdate?.call(state);

    final completed =
        <int, ({ScheduledGame slot, PlayedGame game, DateTime startedAt})>{};
    final slots = <_EngineSlot>[];
    var next = 0;
    String? fatal;

    Future<void> worker(_EngineSlot slot) async {
      while (true) {
        if (_cancelled || fatal != null) return;
        if (next >= schedule.length) return;
        final game = schedule[next++];

        final EngineParticipant white;
        final EngineParticipant black;
        try {
          white = await slot.participant(game.whiteIndex, config, this);
          black = await slot.participant(game.blackIndex, config, this);
        } on UciFailure catch (e) {
          fatal ??= e.message;
          return;
        } catch (e) {
          fatal ??= '$e';
          return;
        }

        onGameStarted?.call(game);
        final startedAt = DateTime.now();
        final played = await const EngineGameRunner().play(
          white: white,
          black: black,
          context: GamePgnContext(
            event: config.name,
            site: config.site,
            round: game.round,
            startFen: config.startFen,
            timeControl: config.timeControl,
            openingLabel: config.openingLabel,
            annotateMoves: config.annotateMoves,
          ),
          adjudication: config.adjudication,
          startedAt: startedAt,
          onMove: onMove == null ? null : (move) => onMove(game, move),
          isCancelled: () => _cancelled,
        );

        completed[game.index] = (
          slot: game,
          game: played,
          startedAt: startedAt,
        );
        onGameFinished?.call(game, played);
        onLog?.call(
          'Game ${game.index + 1}/${schedule.length}: '
          '${white.name} vs ${black.name} — ${played.result.pgnToken} '
          '(${played.termination.label}, ${played.plies} plies)',
        );

        state = await _persist(state, completed);
        onUpdate?.call(state);

        // An engine that died takes its process with it; drop it so the next
        // game in this slot starts a fresh one instead of failing instantly.
        slot.dropDeadEngines();
      }
    }

    try {
      final lanes = config.concurrency.clamp(1, schedule.length);
      slots.addAll(List.generate(lanes, (_) => _EngineSlot()));
      await Future.wait(slots.map(worker));
    } finally {
      for (final slot in slots) {
        await slot.disposeAll();
      }
    }

    if (fatal != null) {
      state = state.copyWith(
        status: TournamentStatus.failed,
        finishedAt: DateTime.now(),
        error: fatal,
      );
    } else {
      state = state.copyWith(
        status: _cancelled
            ? TournamentStatus.cancelled
            : TournamentStatus.completed,
        finishedAt: DateTime.now(),
      );
    }
    await store.save(state);
    onUpdate?.call(state);
    return state;
  }

  Future<StoredTournament> _persist(
    StoredTournament state,
    Map<int, ({ScheduledGame slot, PlayedGame game, DateTime startedAt})>
    completed,
  ) async {
    final ordered = completed.keys.toList()..sort();
    final config = state.config;
    final records = <TournamentGameRecord>[];
    final pgns = <String>[];
    for (var i = 0; i < ordered.length; i++) {
      final entry = completed[ordered[i]]!;
      records.add(
        TournamentGameRecord(
          gameIndex: i,
          round: entry.slot.round,
          whiteIndex: entry.slot.whiteIndex,
          blackIndex: entry.slot.blackIndex,
          whiteName: config.engines[entry.slot.whiteIndex].name,
          blackName: config.engines[entry.slot.blackIndex].name,
          result: entry.game.result,
          termination: entry.game.termination,
          detail: entry.game.detail,
          plies: entry.game.plies,
          startedAt: entry.startedAt,
          durationMs: entry.game.duration.inMilliseconds,
        ),
      );
      pgns.add(entry.game.pgn);
    }
    final updated = state.copyWith(games: records);
    await store.writeGamesPgn(state.id, pgns);
    await store.save(updated);
    return updated;
  }

  Future<StoredTournament> _fail(
    StoredTournament tournament,
    String message,
  ) async {
    final failed = tournament.copyWith(
      status: TournamentStatus.failed,
      finishedAt: DateTime.now(),
      error: message,
    );
    await store.save(failed);
    return failed;
  }
}

/// One lane of concurrent play, holding its own processes.
///
/// Keyed by participant index rather than engine id: an engine playing itself
/// is two processes, and they must not be the same one.
class _EngineSlot {
  final Map<int, EngineParticipant> _participants = {};

  Future<EngineParticipant> participant(
    int index,
    TournamentConfig config,
    EngineTournamentRunner runner,
  ) async {
    final existing = _participants[index];
    if (existing != null && existing.engine.isAlive) return existing;
    _participants.remove(index);

    final spec = config.engines[index];
    final path = await runner.resolveExecutable(spec);
    final engine = await UciEngine.launch(
      executablePath: path,
      arguments: spec.arguments,
    );
    try {
      final identity = await engine.initialize();
      if (identity.supportsOption('Hash')) {
        await engine.setOption('Hash', '${spec.hashMb}');
      }
      if (identity.supportsOption('Threads')) {
        await engine.setOption('Threads', '${spec.threads}');
      }
      if (identity.supportsOption('Ponder')) {
        await engine.setOption('Ponder', spec.ponder ? 'true' : 'false');
      }
      for (final option in spec.options.entries) {
        await engine.setOption(option.key, option.value);
      }
      await engine.isReady();
    } catch (e) {
      await engine.quit();
      if (e is UciFailure) {
        throw UciFailure('${spec.name}: ${e.message}');
      }
      rethrow;
    }

    final participant = EngineParticipant(
      index: index,
      spec: spec,
      engine: engine,
    );
    _participants[index] = participant;
    return participant;
  }

  void dropDeadEngines() {
    _participants.removeWhere((_, participant) {
      if (participant.engine.isAlive) return false;
      participant.engine.dispose();
      return true;
    });
  }

  Future<void> disposeAll() async {
    final all = _participants.values.toList();
    _participants.clear();
    for (final participant in all) {
      await participant.engine.quit();
    }
  }
}
