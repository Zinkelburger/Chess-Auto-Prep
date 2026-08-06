/// A USCF-approximate Swiss pairing engine.
///
/// Pure Dart: no engine, no network, no Flutter. Deterministic given its
/// inputs, so the Monte Carlo simulator can run it thousands of times and
/// tests can assert exact pairings.
///
/// ## Fidelity, and why approximate is the right target
///
/// This implements the load-bearing parts of USCF Chapter 29: score groups,
/// the top-half/bottom-half cross-pairing that makes round 1 nearly
/// deterministic, no-repeat pairings, color equalization and alternation,
/// pair-downs from odd score groups, and the odd-field bye.
///
/// It deliberately does *not* implement the full transposition and interchange
/// limits (the 80-point and 200-point rules), rating-floor special cases, or
/// TD discretion. Those matter for producing a defensible official wall chart;
/// they do not measurably move a *probability distribution* over opponents,
/// because the uncertainty in who actually wins each game dominates them by a
/// wide margin. Chasing exact rule compliance here would buy precision the
/// result model cannot use.
///
/// Where a constraint genuinely cannot be satisfied, the pairing is emitted
/// with `forced: true` rather than silently violated or dropped.
library;

import '../models/pairing.dart';
import '../models/roster_entry.dart';

/// Event shape and pairing options.
class SwissRules {
  final int rounds;

  /// Accelerated pairings: the initial top half carries a virtual point for
  /// the first [acceleratedRounds] rounds, which pushes strong players against
  /// each other sooner. Announced by the organizer; never auto-detected.
  final bool accelerated;
  final int acceleratedRounds;

  /// Pairs that must never meet (family, club-mates, TD instruction).
  final List<PairingConstraint> constraints;

  const SwissRules({
    this.rounds = 5,
    this.accelerated = false,
    this.acceleratedRounds = 2,
    this.constraints = const [],
  });
}

/// Mutable per-player pairing state across an event.
class _PlayerState {
  final String id;
  final int rating;
  final int initialSeed;
  final Set<int> halfPointByeRounds;

  double score;
  final Set<String> opponents = {};
  int colorBalance = 0; // whites − blacks
  PairingColor? lastColor;
  bool hadFullPointBye = false;

  _PlayerState({
    required this.id,
    required this.rating,
    required this.initialSeed,
    required this.halfPointByeRounds,
    required this.score,
  });
}

class SwissPairer {
  final SwissRules rules;
  final List<_PlayerState> _players;
  final Map<String, _PlayerState> _byId;

  /// Number of rounds already paired.
  int _roundsPaired = 0;

  SwissPairer({required List<SwissSeed> seeds, this.rules = const SwissRules()})
    : _players = [],
      _byId = {} {
    // Seed order defines the initial rating list, which accelerated pairings
    // and round-1 colors both key off. Ties break by id so the order is total
    // and every trial of the simulator agrees.
    final sorted = [...seeds]
      ..sort((a, b) {
        final byRating = b.rating.compareTo(a.rating);
        return byRating != 0 ? byRating : a.id.compareTo(b.id);
      });

    for (var i = 0; i < sorted.length; i++) {
      final s = sorted[i];
      final state = _PlayerState(
        id: s.id,
        rating: s.rating,
        initialSeed: i,
        halfPointByeRounds: s.halfPointByeRounds,
        score: s.initialScore,
      );
      _players.add(state);
      _byId[s.id] = state;
    }
  }

  int get roundsPaired => _roundsPaired;
  int get playerCount => _players.length;

  double scoreOf(String id) => _byId[id]?.score ?? 0.0;

  List<SwissStanding> standings() {
    final sorted = [..._players]
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        final byRating = b.rating.compareTo(a.rating);
        return byRating != 0 ? byRating : a.id.compareTo(b.id);
      });
    return sorted
        .map(
          (p) => SwissStanding(
            playerId: p.id,
            score: p.score,
            rating: p.rating,
            colorBalance: p.colorBalance,
          ),
        )
        .toList();
  }

  /// Pair the next round.
  RoundPairings nextRound() {
    final round = _roundsPaired + 1;

    // Requested half-point byes sit out and score 0.5.
    final byes = <ByeAssignment>[];
    final pool = <_PlayerState>[];
    for (final p in _players) {
      if (p.halfPointByeRounds.contains(round)) {
        byes.add(ByeAssignment(playerId: p.id, points: 0.5, requested: true));
      } else {
        pool.add(p);
      }
    }

    // Odd field → one full-point bye, to the lowest-rated player in the lowest
    // score group who has not already had one.
    if (pool.length.isOdd) {
      final candidate = _selectByePlayer(pool);
      if (candidate != null) {
        pool.remove(candidate);
        candidate.hadFullPointBye = true;
        byes.add(
          ByeAssignment(playerId: candidate.id, points: 1.0, requested: false),
        );
      }
    }

    final pairings = _pairPool(pool, round);
    _roundsPaired = round;

    return RoundPairings(round: round, pairings: pairings, byes: byes);
  }

  /// Record the outcome of a paired round.
  ///
  /// [whiteScores] maps each board's white player id to the points White
  /// scored (1.0, 0.5, or 0.0). Byes in [pairings] are applied automatically.
  void recordResults(RoundPairings pairings, Map<String, double> whiteScores) {
    for (final p in pairings.pairings) {
      final white = _byId[p.whiteId];
      final black = _byId[p.blackId];
      if (white == null || black == null) continue;

      final ws = whiteScores[p.whiteId] ?? 0.5;
      white.score += ws;
      black.score += 1.0 - ws;

      white.opponents.add(black.id);
      black.opponents.add(white.id);

      white.colorBalance += 1;
      black.colorBalance -= 1;
      white.lastColor = PairingColor.white;
      black.lastColor = PairingColor.black;
    }

    for (final b in pairings.byes) {
      _byId[b.playerId]?.score += b.points;
    }
  }

  // ── Internals ──────────────────────────────────────────────────────────

  _PlayerState? _selectByePlayer(List<_PlayerState> pool) {
    final eligible = pool.where((p) => !p.hadFullPointBye).toList();
    final from = eligible.isEmpty ? pool : eligible;
    if (from.isEmpty) return null;

    // Lowest score first, then lowest rating.
    from.sort((a, b) {
      final byScore = a.score.compareTo(b.score);
      if (byScore != 0) return byScore;
      final byRating = a.rating.compareTo(b.rating);
      return byRating != 0 ? byRating : a.id.compareTo(b.id);
    });
    return from.first;
  }

  /// Effective score for grouping — real score plus any acceleration bonus.
  double _effectiveScore(_PlayerState p, int round) {
    if (!rules.accelerated || round > rules.acceleratedRounds) return p.score;
    final topHalf = p.initialSeed < (_players.length / 2).ceil();
    return p.score + (topHalf ? 1.0 : 0.0);
  }

  List<Pairing> _pairPool(List<_PlayerState> pool, int round) {
    if (pool.isEmpty) return const [];

    // Descending score groups, each internally ordered by rating.
    final groups = <double, List<_PlayerState>>{};
    for (final p in pool) {
      groups.putIfAbsent(_effectiveScore(p, round), () => []).add(p);
    }
    final scores = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    final pairings = <Pairing>[];
    final carried = <_PlayerState>[];
    var board = 1;

    for (final score in scores) {
      final group = [...carried, ...groups[score]!];
      carried.clear();

      _sortForPairing(group);

      // An odd group pairs down its lowest-ranked player into the next group.
      if (group.length.isOdd) {
        carried.add(group.removeLast());
      }

      // Players this group could not pair legally also drop into the next
      // score group, which is what a TD does rather than forcing a rematch.
      final deferred = <_PlayerState>[];
      board = _crossPair(group, pairings, board, deferred);
      carried.addAll(deferred);
    }

    // Whatever is still carried has run out of score groups to drop into.
    // Only here do we accept illegal pairings, and they are flagged as forced.
    if (carried.length >= 2) {
      _sortForPairing(carried);
      board = _forcePair(carried, pairings, board);
    }

    return pairings;
  }

  /// Last resort: pair everyone left over, legality be damned, flagging each
  /// board that violates a constraint.
  int _forcePair(List<_PlayerState> rest, List<Pairing> out, int startBoard) {
    var board = startBoard;
    for (var i = 0; i + 1 < rest.length; i += 2) {
      final a = rest[i];
      final b = rest[i + 1];
      final (white, black) = _assignColors(a, b, board);
      out.add(
        Pairing(
          board: board,
          whiteId: white.id,
          blackId: black.id,
          forced: !_isLegal(a, b),
        ),
      );
      board++;
    }
    return board;
  }

  void _sortForPairing(List<_PlayerState> group) {
    group.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byRating = b.rating.compareTo(a.rating);
      if (byRating != 0) return byRating;
      return a.id.compareTo(b.id);
    });
  }

  /// Split [group] in half and pair each top-half player against the
  /// rating-appropriate bottom-half player, transposing when that pairing is
  /// illegal.
  ///
  /// Candidates are *removed* from the pool as they are used rather than
  /// swapped by index, so a transposition can never disturb a board that has
  /// already been emitted.
  ///
  /// Players with no legal partner left are appended to [deferred] for the
  /// caller to drop into the next score group.
  int _crossPair(
    List<_PlayerState> group,
    List<Pairing> out,
    int startBoard,
    List<_PlayerState> deferred,
  ) {
    var board = startBoard;
    if (group.length < 2) {
      deferred.addAll(group);
      return board;
    }

    final half = group.length ~/ 2;
    final top = group.sublist(0, half);
    final bottom = group.sublist(half);

    for (final a in top) {
      final partner = _findPartner(a, bottom);
      if (partner == null) {
        deferred.add(a);
        continue;
      }

      final b = bottom.removeAt(partner);
      final (white, black) = _assignColors(a, b, board);
      out.add(Pairing(board: board, whiteId: white.id, blackId: black.id));
      board++;
    }

    // Bottom-half players nobody could take drop down with the top-half ones.
    deferred.addAll(bottom);
    return board;
  }

  /// Index into [bottom] of the player who should face [a], or null when no
  /// legal partner remains.
  ///
  /// Scans in rating order so the pairing stays as close to the correct one as
  /// possible, and among the first [_colorSearchWindow] legal candidates
  /// prefers one whose color preference opposes [a]'s. Beyond that window the
  /// rating distortion outweighs the color benefit — the same trade-off the
  /// rulebook's transposition limits encode.
  int? _findPartner(_PlayerState a, List<_PlayerState> bottom) {
    int? fallback;
    var examined = 0;

    for (var j = 0; j < bottom.length; j++) {
      if (!_isLegal(a, bottom[j])) continue;
      fallback ??= j;
      if (_colorsCompatible(a, bottom[j])) return j;
      if (++examined >= _colorSearchWindow) break;
    }

    return fallback;
  }

  static const int _colorSearchWindow = 4;

  /// Whether [a] and [b] want opposite colors (or at least one is indifferent).
  bool _colorsCompatible(_PlayerState a, _PlayerState b) {
    final pa = _colorPreference(a);
    final pb = _colorPreference(b);
    return pa == 0 || pb == 0 || pa != pb;
  }

  /// +1 = due White, −1 = due Black, 0 = no preference.
  ///
  /// Equalization (an unbalanced color count) outranks alternation (the last
  /// color played), matching USCF 29E.
  int _colorPreference(_PlayerState p) {
    if (p.colorBalance < 0) return 1;
    if (p.colorBalance > 0) return -1;
    if (p.lastColor == PairingColor.black) return 1;
    if (p.lastColor == PairingColor.white) return -1;
    return 0;
  }

  bool _isLegal(_PlayerState a, _PlayerState b) {
    if (a.id == b.id) return false;
    if (a.opponents.contains(b.id)) return false;
    for (final c in rules.constraints) {
      if (c.involves(a.id, b.id)) return false;
    }
    return true;
  }

  /// Decide colors: equalize imbalance first, then alternate, then fall back
  /// to alternating down the boards (the round-1 convention).
  (_PlayerState, _PlayerState) _assignColors(
    _PlayerState a,
    _PlayerState b,
    int board,
  ) {
    if (a.colorBalance != b.colorBalance) {
      // The player who has had more Blacks (lower balance) is due White.
      return a.colorBalance < b.colorBalance ? (a, b) : (b, a);
    }

    if (a.lastColor != b.lastColor) {
      if (a.lastColor == PairingColor.black) return (a, b);
      if (b.lastColor == PairingColor.black) return (b, a);
    }

    // Both equally due: the higher-ranked player takes White on odd boards and
    // Black on even ones, reproducing the standard round-1 pairing sheet.
    return board.isOdd ? (a, b) : (b, a);
  }
}
