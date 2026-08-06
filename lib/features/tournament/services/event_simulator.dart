/// Monte Carlo simulation of a Swiss event, to answer "who am I likely to
/// play?" without pretending to predict the actual pairing sheet.
///
/// ## Why sampling rather than prediction
///
/// Predicting a specific pairing is not achievable: withdrawals, late entries,
/// family/club withholds, half-point byes and TD discretion all move the
/// sheet, and none of them are knowable in advance. But prep does not need the
/// sheet — it needs P(face this person), which is stable under exactly that
/// noise. Running the whole event thousands of times and counting opponents
/// gives that directly, and every source of mess above enters as a parameter
/// rather than as an unmodelled error.
///
/// Round 1 comes out near-deterministic (a spike on one opponent, because
/// round 1 is a plain top-half/bottom-half split), and later rounds diffuse
/// toward "the players near my rating" — which is the honest answer.
///
/// Pure Dart and deterministic given [SimulationConfig.seed], so results are
/// reproducible and testable.
library;

import 'dart:math' as math;

import '../models/opponent_probability.dart';
import '../models/pairing.dart';
import '../models/roster_entry.dart';
import 'swiss_pairer.dart';

class SimulationConfig {
  /// Number of simulated events. 2000 puts the standard error on a mid-range
  /// probability near one percentage point, which is well inside the accuracy
  /// the rating model itself can claim.
  final int trials;

  /// Seed for reproducibility.
  final int seed;

  /// Draw rate between equally-rated players. Scaled down as the rating gap
  /// widens, since mismatches draw less often.
  final double drawRate;

  /// Rating assumed for unrated entrants. Defaults to the field median when
  /// null, which is a better guess than any fixed constant.
  final int? unratedRating;

  const SimulationConfig({
    this.trials = 2000,
    this.seed = 20260806,
    this.drawRate = 0.30,
    this.unratedRating,
  });
}

class EventSimulator {
  /// Simulate [roster] and return per-opponent pairing probabilities for the
  /// entrant flagged [RosterEntry.isMe].
  static SimulationResult run(
    Roster roster, {
    SimulationConfig config = const SimulationConfig(),
  }) {
    final notes = <String>[];

    final me = roster.me;
    if (me == null) {
      return const SimulationResult(
        opponents: [],
        trials: 0,
        rounds: 0,
        expectedScore: 0,
        byeProb: 0,
        notes: [
          'No entrant is marked as you, so there is no reference point for '
              'pairing probabilities. Mark yourself on the roster first.',
        ],
      );
    }

    // Only entrants in your own section can ever be paired against you.
    final field = roster.sectionOf(me);
    if (field.length < 2) {
      return SimulationResult(
        opponents: const [],
        trials: 0,
        rounds: roster.rounds,
        expectedScore: 0,
        byeProb: 0,
        notes: [
          'Section "${me.section ?? 'open'}" has ${field.length} entrant(s) — '
              'nothing to simulate.',
        ],
      );
    }
    if (roster.sections.isNotEmpty) {
      if (me.section == null || me.section!.isEmpty) {
        // Over-including is the safe direction — prep you don't need beats
        // missing a real opponent — but claiming we filtered when we did not
        // would be a lie the user acts on.
        notes.add(
          'You have no section, but this event has '
          '${roster.sections.length} (${roster.sections.join(', ')}). '
          'Simulating against ALL ${field.length} entrants, which will '
          'include players you cannot be paired with. Set your section for '
          'accurate pairing probabilities.',
        );
      } else if (roster.sections.length > 1) {
        notes.add(
          'Simulating section "${me.section}" only '
          '(${field.length} of ${roster.active.length} entrants).',
        );
      }
    }

    final ratings = _resolveRatings(field, config, notes);
    final rounds = roster.rounds;
    final rules = SwissRules(
      rounds: rounds,
      accelerated: roster.accelerated,
      constraints: roster.constraints,
    );

    final faceCount = <String, int>{};
    final faceWhite = <String, int>{};
    final faceBlack = <String, int>{};
    final faceByRound = <String, List<int>>{};
    var byeTrials = 0;
    var scoreTotal = 0.0;
    var forcedTotal = 0;

    final rng = math.Random(config.seed);

    for (var trial = 0; trial < config.trials; trial++) {
      // Sample who actually shows up. You are always present.
      final present = <RosterEntry>[];
      for (final e in field) {
        if (e.isMe ||
            e.attendanceProb >= 1.0 ||
            rng.nextDouble() < e.attendanceProb) {
          present.add(e);
        }
      }
      if (present.length < 2) continue;

      final pairer = SwissPairer(
        seeds: present
            .map(
              (e) => SwissSeed(
                id: e.id,
                rating: ratings[e.id]!,
                halfPointByeRounds: e.halfPointByeRounds,
              ),
            )
            .toList(),
        rules: rules,
      );

      final facedThisTrial = <String>{};
      var gotBye = false;

      for (var r = 1; r <= rounds; r++) {
        final sheet = pairer.nextRound();
        forcedTotal += sheet.forcedCount;

        final myPairing = sheet.forPlayer(me.id);
        if (myPairing == null) {
          if (sheet.hasBye(me.id)) gotBye = true;
        } else {
          final oppId = myPairing.opponentOf(me.id)!;
          facedThisTrial.add(oppId);
          faceByRound.putIfAbsent(oppId, () => List.filled(rounds, 0));
          faceByRound[oppId]![r - 1]++;
          if (myPairing.colorOf(me.id) == PairingColor.white) {
            faceWhite[oppId] = (faceWhite[oppId] ?? 0) + 1;
          } else {
            faceBlack[oppId] = (faceBlack[oppId] ?? 0) + 1;
          }
        }

        pairer.recordResults(
          sheet,
          _simulateBoards(sheet, ratings, config, rng),
        );
      }

      for (final id in facedThisTrial) {
        faceCount[id] = (faceCount[id] ?? 0) + 1;
      }
      if (gotBye) byeTrials++;
      scoreTotal += pairer.scoreOf(me.id);
    }

    final trials = config.trials;
    final opponents =
        faceCount.entries.map((e) {
          final id = e.key;
          final rounds0 = faceByRound[id] ?? List.filled(rounds, 0);
          return OpponentProbability(
            playerId: id,
            probAny: e.value / trials,
            probAsWhite: (faceWhite[id] ?? 0) / trials,
            probAsBlack: (faceBlack[id] ?? 0) / trials,
            probByRound: rounds0.map((c) => c / trials).toList(),
          );
        }).toList()..sort((a, b) {
          final byProb = b.probAny.compareTo(a.probAny);
          return byProb != 0 ? byProb : a.playerId.compareTo(b.playerId);
        });

    return SimulationResult(
      opponents: opponents,
      trials: trials,
      rounds: rounds,
      expectedScore: trials == 0 ? 0 : scoreTotal / trials,
      byeProb: trials == 0 ? 0 : byeTrials / trials,
      meanForcedPairings: trials == 0 ? 0 : forcedTotal / trials,
      notes: notes,
    );
  }

  /// Result of every board in a round, as a map of white-player id → points
  /// scored by White.
  static Map<String, double> _simulateBoards(
    RoundPairings sheet,
    Map<String, int> ratings,
    SimulationConfig config,
    math.Random rng,
  ) {
    final out = <String, double>{};
    for (final p in sheet.pairings) {
      final rw = ratings[p.whiteId] ?? 1200;
      final rb = ratings[p.blackId] ?? 1200;
      out[p.whiteId] = _sampleResult(rw, rb, config.drawRate, rng);
    }
    return out;
  }

  /// Sample one game result from White's perspective (1.0 / 0.5 / 0.0).
  ///
  /// Elo gives the expected score; the draw rate is scaled by how close the
  /// pairing is, because lopsided games are decisive far more often than even
  /// ones. Win and loss then split the remainder so the mean still equals the
  /// Elo expectation.
  static double _sampleResult(
    int whiteRating,
    int blackRating,
    double baseDrawRate,
    math.Random rng,
  ) {
    final expected =
        1.0 / (1.0 + math.pow(10, (blackRating - whiteRating) / 400.0));
    final closeness = 1.0 - (2 * expected - 1).abs();
    final pDraw = (baseDrawRate * closeness).clamp(0.0, 1.0);
    var pWin = expected - pDraw / 2;
    pWin = pWin.clamp(0.0, 1.0 - pDraw);

    final roll = rng.nextDouble();
    if (roll < pWin) return 1.0;
    if (roll < pWin + pDraw) return 0.5;
    return 0.0;
  }

  /// Fill in ratings for unrated entrants, defaulting to the field median.
  static Map<String, int> _resolveRatings(
    List<RosterEntry> field,
    SimulationConfig config,
    List<String> notes,
  ) {
    final rated = field.where((e) => e.isRated).map((e) => e.rating!).toList()
      ..sort();

    final fallback =
        config.unratedRating ??
        (rated.isEmpty ? 1200 : rated[rated.length ~/ 2]);

    final unratedCount = field.length - rated.length;
    if (unratedCount > 0) {
      notes.add(
        '$unratedCount unrated entrant(s) seeded at $fallback '
        '(${config.unratedRating != null ? 'configured' : 'field median'}).',
      );
    }

    return {for (final e in field) e.id: e.rating ?? fallback};
  }
}
