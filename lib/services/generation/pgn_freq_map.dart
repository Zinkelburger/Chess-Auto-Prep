/// Position → move statistics harvested from a PGN game database.
///
/// This is the app's model of *human practice*: for every position reached,
/// which moves were played, how often, how they scored, at what strength, and
/// how recently.  It is deliberately more than a frequency table — an eval
/// tells you what is best, this tells you what actually happens, and the two
/// disagreeing is the most useful signal in opening preparation.
///
/// A bounded sample of the strongest games is retained whole (see
/// [TopGamesReservoir]) so the course exporter can show model games without a
/// second pass over the source files.
///
/// Parsing lives in `pgn_freq_parser.dart`; this file is pure data and is
/// isolate-transferable.
library;

import '../eval/eval_canonicalize.dart';

const kDefaultStartFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

// ── Game outcome ─────────────────────────────────────────────────────────

/// The three PGN result tokens that carry information (`*` is "unknown").
enum GameOutcome {
  whiteWin,
  draw,
  blackWin;

  /// Parse a PGN `[Result]` value; null for `*` and anything unrecognised.
  static GameOutcome? parse(String? token) => switch (token?.trim()) {
    '1-0' => GameOutcome.whiteWin,
    '0-1' => GameOutcome.blackWin,
    '1/2-1/2' || '½-½' => GameOutcome.draw,
    _ => null,
  };

  String get pgnToken => switch (this) {
    GameOutcome.whiteWin => '1-0',
    GameOutcome.draw => '1/2-1/2',
    GameOutcome.blackWin => '0-1',
  };

  /// Score for one side in [0, 1] — 1 win, ½ draw, 0 loss.
  double scoreFor({required bool asWhite}) => switch (this) {
    GameOutcome.draw => 0.5,
    GameOutcome.whiteWin => asWhite ? 1.0 : 0.0,
    GameOutcome.blackWin => asWhite ? 0.0 : 1.0,
  };
}

// ── Per-move statistics ──────────────────────────────────────────────────

/// One move played from one position, with everything the database knows
/// about how it went.
///
/// Counters are mutable because accumulation is the hot path of a database
/// scan; treat an instance as immutable once parsing has finished.
class PgnFreqMove {
  final String uci;
  final String san;

  /// Games in which this move was played.  Always ≥ the sum of the three
  /// outcome counters — games with a `*` result contribute here only.
  int count;

  int whiteWins;
  int draws;
  int blackWins;

  /// Sum of per-game average Elo, over games where both ratings were known.
  /// Kept as a sum + count so maps can be merged without weighting errors.
  int eloSum;
  int eloCount;

  /// Most recent year this move was played (0 when no game carried a date).
  int lastYear;

  PgnFreqMove({
    required this.uci,
    required this.san,
    this.count = 1,
    this.whiteWins = 0,
    this.draws = 0,
    this.blackWins = 0,
    this.eloSum = 0,
    this.eloCount = 0,
    this.lastYear = 0,
  });

  /// Games with a known result — the denominator for [scoreFor].
  int get decidedGames => whiteWins + draws + blackWins;

  /// Score from [asWhite]'s perspective: `(wins + ½·draws) / decided`.
  /// Null when no game at this move had a recorded result, which is the
  /// honest answer — 0.5 would look like a measurement.
  double? scoreFor({required bool asWhite}) {
    final decided = decidedGames;
    if (decided == 0) return null;
    final wins = asWhite ? whiteWins : blackWins;
    return (wins + 0.5 * draws) / decided;
  }

  /// Mean rating of the players who chose this move, or null if unrated.
  int? get averageElo => eloCount == 0 ? null : eloSum ~/ eloCount;

  void record({GameOutcome? outcome, int? averageElo, int? year}) {
    count++;
    switch (outcome) {
      case GameOutcome.whiteWin:
        whiteWins++;
      case GameOutcome.draw:
        draws++;
      case GameOutcome.blackWin:
        blackWins++;
      case null:
        break;
    }
    if (averageElo != null && averageElo > 0) {
      eloSum += averageElo;
      eloCount++;
    }
    if (year != null && year > lastYear) lastYear = year;
  }

  void absorb(PgnFreqMove other) {
    count += other.count;
    whiteWins += other.whiteWins;
    draws += other.draws;
    blackWins += other.blackWins;
    eloSum += other.eloSum;
    eloCount += other.eloCount;
    if (other.lastYear > lastYear) lastYear = other.lastYear;
  }
}

// ── Per-position statistics ──────────────────────────────────────────────

class PgnFreqPosition {
  final String fenKey;

  /// How many games reached this position.
  int reachCount = 0;

  final List<PgnFreqMove> moves = [];

  /// Indices into [PgnFreqMap.games] for retained games passing through here,
  /// newest-inserted last.  Bounded by [maxGameRefsPerPosition].
  final List<int> gameRefs = [];

  PgnFreqPosition(this.fenKey);

  /// Cap on retained game references per position.  Model-game selection only
  /// ever shows a handful, and an unbounded list on a heavily-transposed
  /// tabiya would dominate the cache file.
  static const int maxGameRefsPerPosition = 24;

  /// Total games across all recorded moves — the denominator to use when
  /// [reachCount] is unavailable (legacy caches recorded moves only).
  int get playedTotal => moves.fold(0, (sum, m) => sum + m.count);

  PgnFreqMove? move(String uci) {
    for (final m in moves) {
      if (m.uci == uci) return m;
    }
    return null;
  }

  void addGameRef(int index) {
    if (gameRefs.length >= maxGameRefsPerPosition) return;
    if (gameRefs.contains(index)) return;
    gameRefs.add(index);
  }
}

// ── Retained games ───────────────────────────────────────────────────────

/// A whole game kept from the source database, strong enough to be worth
/// showing as a model game.
class PgnGameRecord {
  final String white;
  final String black;
  final int whiteElo;
  final int blackElo;
  final String event;
  final String date;
  final GameOutcome? outcome;

  /// SAN moves, truncated to [maxRetainedPlies].
  final List<String> movesSan;

  const PgnGameRecord({
    required this.white,
    required this.black,
    required this.whiteElo,
    required this.blackElo,
    required this.event,
    required this.date,
    required this.outcome,
    required this.movesSan,
  });

  /// Games longer than this are truncated: a model game's teaching value is
  /// in the opening and early middlegame, and the tail is mostly technique.
  static const int maxRetainedPlies = 120;

  /// Rating strength used for admission and ranking.  Falls back to whichever
  /// single rating is known, then 0.
  int get averageElo {
    if (whiteElo > 0 && blackElo > 0) return (whiteElo + blackElo) ~/ 2;
    return whiteElo > 0 ? whiteElo : blackElo;
  }

  int? get year {
    final match = RegExp(r'(\d{4})').firstMatch(date);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  bool get isDecisive =>
      outcome == GameOutcome.whiteWin || outcome == GameOutcome.blackWin;

  /// True when [asWhite]'s side won.
  bool wonBy({required bool asWhite}) =>
      outcome == (asWhite ? GameOutcome.whiteWin : GameOutcome.blackWin);

  /// `Kasparov, G – Karpov, A` with `?`/empty names elided.
  String get playersLabel {
    final w = white.isEmpty || white == '?' ? null : white;
    final b = black.isEmpty || black == '?' ? null : black;
    if (w == null && b == null) return 'Unknown players';
    return '${w ?? '?'} – ${b ?? '?'}';
  }
}

/// Keeps the highest-rated [capacity] games seen, in O(1) amortized time.
///
/// Admission is by [PgnGameRecord.averageElo].  Rather than maintaining a
/// heap, entries accumulate to twice the capacity and are then sorted and
/// truncated, which raises [admissionElo] and rejects most later candidates
/// outright — a database scan spends almost no time here.
class TopGamesReservoir {
  TopGamesReservoir({this.capacity = defaultCapacity});

  static const int defaultCapacity = 512;

  final int capacity;
  final List<PgnGameRecord> _entries = [];

  /// Lowest average Elo currently retained; candidates below it are dropped
  /// without allocating.  0 until the reservoir has overflowed once.
  int admissionElo = 0;

  List<PgnGameRecord> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  /// Offer [game]; returns its index when retained, or null when rejected.
  ///
  /// The index is stable only until the next [_compact], so callers that
  /// store it must re-map through [compactIndices] afterwards.  In practice
  /// only the parser holds indices, and it re-maps on every compaction.
  int? offer(PgnGameRecord game) {
    if (capacity <= 0) return null;
    if (_entries.length >= capacity && game.averageElo < admissionElo) {
      return null;
    }
    _entries.add(game);
    return _entries.length - 1;
  }

  /// True when the reservoir has grown past its compaction watermark.
  bool get needsCompaction => _entries.length >= capacity * 2;

  /// Sort by strength, truncate to [capacity], and return the old-index →
  /// new-index mapping (missing keys were evicted).
  Map<int, int> compactIndices() {
    final ordered = List.generate(
      _entries.length,
      (i) => i,
    )..sort((a, b) => _entries[b].averageElo.compareTo(_entries[a].averageElo));
    final kept = ordered.take(capacity).toList();
    final remap = <int, int>{};
    final compacted = <PgnGameRecord>[];
    for (final oldIndex in kept) {
      remap[oldIndex] = compacted.length;
      compacted.add(_entries[oldIndex]);
    }
    _entries
      ..clear()
      ..addAll(compacted);
    admissionElo = _entries.isEmpty ? 0 : _entries.last.averageElo;
    return remap;
  }

  /// Merge [other] in, returning its old-index → new-index mapping so the
  /// caller can rewrite position game-refs.  Entries that lose the cut are
  /// absent from the map.
  Map<int, int> absorb(TopGamesReservoir other) {
    final offered = <int, int>{};
    for (var i = 0; i < other._entries.length; i++) {
      final index = offer(other._entries[i]);
      if (index != null) offered[i] = index;
    }
    if (!needsCompaction) return offered;
    final remap = compactIndices();
    return {
      for (final entry in offered.entries)
        if (remap.containsKey(entry.value)) entry.key: remap[entry.value]!,
    };
  }

  /// Final ordering: strongest first.  Call once parsing is complete.
  Map<int, int> finalize() => compactIndices();

  void addAllUnchecked(Iterable<PgnGameRecord> games) => _entries.addAll(games);
}

// ── The map ──────────────────────────────────────────────────────────────

class PgnFreqMap {
  PgnFreqMap({int gameCapacity = TopGamesReservoir.defaultCapacity})
    : games = TopGamesReservoir(capacity: gameCapacity);

  final Map<String, PgnFreqPosition> _positions = {};

  /// Strongest games retained whole, for model-game selection.
  final TopGamesReservoir games;

  int totalGames = 0;

  int get positionCount => _positions.length;

  /// Exposed for disk cache serialization.
  Iterable<MapEntry<String, PgnFreqPosition>> get positions =>
      _positions.entries;

  PgnFreqPosition? get(String fen) => _positions[canonicalizeFen4(fen)];

  PgnFreqPosition getOrCreate(String fenKey) =>
      _positions.putIfAbsent(fenKey, () => PgnFreqPosition(fenKey));

  /// Record one occurrence of [uci] at [fenKey], with whatever game context
  /// the source PGN provided.
  void recordMove(
    String fenKey,
    String uci,
    String san, {
    GameOutcome? outcome,
    int? averageElo,
    int? year,
  }) {
    final pos = getOrCreate(fenKey);
    final existing = pos.move(uci);
    if (existing != null) {
      existing.record(outcome: outcome, averageElo: averageElo, year: year);
      return;
    }
    pos.moves.add(
      PgnFreqMove(uci: uci, san: san, count: 0)
        ..record(outcome: outcome, averageElo: averageElo, year: year),
    );
  }

  void recordReach(String fenKey) => getOrCreate(fenKey).reachCount++;

  /// Moves clearing both a minimum game count and a minimum share of play.
  List<PgnFreqMove> filteredMoves(
    PgnFreqPosition pos, {
    required int minGames,
    required double minProb,
  }) {
    final total = pos.playedTotal;
    if (total == 0) return const [];
    return [
      for (final m in pos.moves)
        if (m.count >= minGames && m.count / total >= minProb) m,
    ];
  }

  /// Merge [other] into this map, summing counters and folding its retained
  /// games into this reservoir (rewriting position game-refs to match).
  void merge(PgnFreqMap other) {
    totalGames += other.totalGames;
    final remap = games.absorb(other.games);

    for (final entry in other._positions.entries) {
      final src = entry.value;
      final dst = getOrCreate(entry.key);
      dst.reachCount += src.reachCount;
      for (final srcMove in src.moves) {
        final dstMove = dst.move(srcMove.uci);
        if (dstMove != null) {
          dstMove.absorb(srcMove);
        } else {
          dst.moves.add(
            PgnFreqMove(uci: srcMove.uci, san: srcMove.san, count: 0)
              ..absorb(srcMove),
          );
        }
      }
      for (final oldIndex in src.gameRefs) {
        final newIndex = remap[oldIndex];
        if (newIndex != null) dst.addGameRef(newIndex);
      }
    }
  }

  /// Rewrite every position's game-refs through [remap], dropping evicted
  /// entries.  Called after the reservoir compacts.
  void remapGameRefs(Map<int, int> remap) {
    for (final pos in _positions.values) {
      if (pos.gameRefs.isEmpty) continue;
      final rewritten = [
        for (final old in pos.gameRefs)
          if (remap.containsKey(old)) remap[old]!,
      ];
      pos.gameRefs
        ..clear()
        ..addAll(rewritten);
    }
  }

  PgnFreqStats get stats =>
      PgnFreqStats(positions: positionCount, totalGames: totalGames);
}

// ── Parse configuration and outcome ──────────────────────────────────────

class PgnFreqConfig {
  final String? startFen;
  final String? startMoves;
  final int maxPly;
  final int minElo;

  /// How many whole games to retain for model-game selection.  0 disables
  /// retention entirely (a pure frequency scan, the cheapest mode).
  final int retainGames;

  /// Rating floor for retention, separate from [minElo] so that raising the
  /// bar for what counts as a *model* game does not shrink the frequency
  /// sample the repertoire is built from.  Games with no rating at all are
  /// still retained — the reservoir ranks them last on its own.
  final int retainMinElo;

  const PgnFreqConfig({
    this.startFen,
    this.startMoves,
    this.maxPly = 0,
    this.minElo = 0,
    this.retainGames = TopGamesReservoir.defaultCapacity,
    this.retainMinElo = 0,
  });
}

class PgnFreqStats {
  final int positions;
  final int totalGames;
  final int skippedElo;
  final int skippedPrefix;
  final int parseErrors;
  final int fileReadErrors;
  final int retainedGames;

  const PgnFreqStats({
    this.positions = 0,
    this.totalGames = 0,
    this.skippedElo = 0,
    this.skippedPrefix = 0,
    this.parseErrors = 0,
    this.fileReadErrors = 0,
    this.retainedGames = 0,
  });
}
