/// Pairing primitives shared by the Swiss pairer and the event simulator.
library;

enum PairingColor { white, black }

/// One board in one round.
class Pairing {
  final int board;
  final String whiteId;
  final String blackId;

  /// True when the pairer could not satisfy every constraint and had to place
  /// an illegal pair (a rematch, or a withhold it could not route around).
  /// Real TDs resolve these by hand; we surface them rather than hide them.
  final bool forced;

  const Pairing({
    required this.board,
    required this.whiteId,
    required this.blackId,
    this.forced = false,
  });

  bool involves(String id) => whiteId == id || blackId == id;

  String? opponentOf(String id) => whiteId == id
      ? blackId
      : blackId == id
      ? whiteId
      : null;

  PairingColor? colorOf(String id) => whiteId == id
      ? PairingColor.white
      : blackId == id
      ? PairingColor.black
      : null;

  Map<String, dynamic> toMap() => {
    'board': board,
    'white': whiteId,
    'black': blackId,
    if (forced) 'forced': true,
  };
}

/// A player sitting out a round.
class ByeAssignment {
  final String playerId;

  /// 1.0 for the odd-field pairing bye, 0.5 for a requested half-point bye.
  final double points;

  /// True when the player asked for it in advance rather than being assigned
  /// one because the field was odd.
  final bool requested;

  const ByeAssignment({
    required this.playerId,
    required this.points,
    required this.requested,
  });

  Map<String, dynamic> toMap() => {
    'player': playerId,
    'points': points,
    'requested': requested,
  };
}

/// The complete pairing sheet for one round.
class RoundPairings {
  final int round;
  final List<Pairing> pairings;
  final List<ByeAssignment> byes;

  const RoundPairings({
    required this.round,
    required this.pairings,
    this.byes = const [],
  });

  /// The board [id] is playing on, or null if they have a bye.
  Pairing? forPlayer(String id) {
    for (final p in pairings) {
      if (p.involves(id)) return p;
    }
    return null;
  }

  String? opponentOf(String id) => forPlayer(id)?.opponentOf(id);

  bool hasBye(String id) => byes.any((b) => b.playerId == id);

  /// Pairings the pairer could not make legally.
  int get forcedCount => pairings.where((p) => p.forced).length;

  Map<String, dynamic> toMap() => {
    'round': round,
    'pairings': pairings.map((p) => p.toMap()).toList(),
    if (byes.isNotEmpty) 'byes': byes.map((b) => b.toMap()).toList(),
  };
}

/// A player as handed to the pairer.
class SwissSeed {
  final String id;
  final int rating;

  /// Rounds this player sits out with a requested half-point bye.
  final Set<int> halfPointByeRounds;

  /// Score carried in before round 1 — nonzero only when resuming a live event
  /// from posted standings.
  final double initialScore;

  const SwissSeed({
    required this.id,
    required this.rating,
    this.halfPointByeRounds = const {},
    this.initialScore = 0.0,
  });
}

/// Standing row after some number of rounds.
class SwissStanding {
  final String playerId;
  final double score;
  final int rating;
  final int colorBalance;

  const SwissStanding({
    required this.playerId,
    required this.score,
    required this.rating,
    required this.colorBalance,
  });
}
