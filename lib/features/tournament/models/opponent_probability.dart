/// Output of the event simulator: how likely each entrant is to end up across
/// the board from you, and with which color.
library;

/// Per-opponent likelihood, split by the color you would hold.
///
/// The color split is load-bearing rather than decorative: prep for an
/// opponent you will face with White is a different repertoire from prep for
/// the same opponent with Black, so the two probabilities drive two separate
/// clash runs.
class OpponentProbability {
  final String playerId;

  /// P(face this player at least once during the event).
  final double probAny;

  /// P(face them at least once *with White*). [probAsWhite] + [probAsBlack]
  /// can exceed [probAny] only in the rare case of facing someone twice,
  /// which standard Swiss pairing forbids.
  final double probAsWhite;
  final double probAsBlack;

  /// P(face them in round r), indexed from 0 = round 1.
  final List<double> probByRound;

  const OpponentProbability({
    required this.playerId,
    required this.probAny,
    required this.probAsWhite,
    required this.probAsBlack,
    required this.probByRound,
  });

  /// The round this pairing is most likely to happen in (1-based), or null
  /// when the player is never faced.
  int? get mostLikelyRound {
    var best = -1;
    var bestValue = 0.0;
    for (var i = 0; i < probByRound.length; i++) {
      if (probByRound[i] > bestValue) {
        bestValue = probByRound[i];
        best = i;
      }
    }
    return best < 0 ? null : best + 1;
  }

  /// Whether prep for this opponent is worth building at all.
  bool meetsThreshold(double minProb) => probAny >= minProb;

  Map<String, dynamic> toMap() => {
    'player': playerId,
    'prob_any': probAny,
    'prob_as_white': probAsWhite,
    'prob_as_black': probAsBlack,
    'prob_by_round': probByRound,
    if (mostLikelyRound != null) 'most_likely_round': mostLikelyRound,
  };
}

/// Aggregate simulation output.
class SimulationResult {
  /// Opponents sorted by [OpponentProbability.probAny], descending.
  final List<OpponentProbability> opponents;

  final int trials;
  final int rounds;

  /// Your mean final score across trials — a sanity check that the rating
  /// model is behaving.
  final double expectedScore;

  /// P(you receive a bye in some round).
  final double byeProb;

  /// Mean number of pairings per trial the pairer could not make legally.
  /// A large value means the constraints are over-tight, not that the field
  /// is unusual.
  final double meanForcedPairings;

  /// Human-readable notes (unrated players defaulted, section ignored, …).
  final List<String> notes;

  const SimulationResult({
    required this.opponents,
    required this.trials,
    required this.rounds,
    required this.expectedScore,
    required this.byeProb,
    this.meanForcedPairings = 0,
    this.notes = const [],
  });

  static const empty = SimulationResult(
    opponents: [],
    trials: 0,
    rounds: 0,
    expectedScore: 0,
    byeProb: 0,
  );

  /// The smallest opponent set covering [coverage] of the total pairing
  /// probability mass — "prep these N and you've covered 80% of the field
  /// you'll actually meet".
  List<OpponentProbability> topByCoverage(double coverage) {
    final total = opponents.fold<double>(0, (s, o) => s + o.probAny);
    if (total <= 0) return const [];
    final target = total * coverage;
    final out = <OpponentProbability>[];
    var acc = 0.0;
    for (final o in opponents) {
      out.add(o);
      acc += o.probAny;
      if (acc >= target) break;
    }
    return out;
  }

  Map<String, dynamic> toMap() => {
    'trials': trials,
    'rounds': rounds,
    'expected_score': expectedScore,
    'bye_prob': byeProb,
    'mean_forced_pairings': meanForcedPairings,
    'opponents': opponents.map((o) => o.toMap()).toList(),
    if (notes.isNotEmpty) 'notes': notes,
  };
}
