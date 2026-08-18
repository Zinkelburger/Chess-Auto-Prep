/// What the planner asks, what it learns, and what it produces.
///
/// A plan is flat: a list of chapters, each a "generate from here" point given
/// by its move path from the start position, plus (for a chapter rooted at an
/// opponent tabiya whose big replies became sibling chapters) the replies it
/// must leave to those siblings. Everything the walk decided is encoded in
/// the paths themselves.
library;

/// One move the user could make (our-move fork) or one reply to cover
/// (their-move node), with whatever evidence the sources returned.
class PlanCandidate {
  final String san;

  /// ECO name and code of the position after [san], if the book has one.
  final String? name;
  final String? eco;

  /// Share of database games (0–1) and the count behind it — only when a
  /// source supplied it (tests / offline files); the live planner does not
  /// query the Lichess explorer for probabilities.
  final double? dbShare;
  final int? dbGames;

  /// Maia's probability for a player of the chosen strength: the planner's
  /// probability of record.
  final double? maiaProb;

  /// Evaluation of the position after [san], white-normalized centipawns,
  /// from ChessDB, the local eval cache, or an on-demand Stockfish run. Null
  /// when unknown. [evalDepth] / [evalSource] say where it came from.
  final int? evalCp;
  final int? evalDepth;
  final String? evalSource;

  /// Share of the user's *own* games (from Player Analysis) in which they
  /// played this here, and the count. Null when there were no games here.
  final double? ownShare;
  final int? ownGames;

  /// The user's existing chapters play this move here.
  final bool inChapters;

  /// How much book lies below this move — the child's tabiya weight.
  final int bookBelow;

  const PlanCandidate({
    required this.san,
    this.name,
    this.eco,
    this.dbShare,
    this.dbGames,
    this.maiaProb,
    this.evalCp,
    this.evalDepth,
    this.evalSource,
    this.ownShare,
    this.ownGames,
    this.inChapters = false,
    this.bookBelow = 0,
  });

  /// The share to rank and threshold by: Maia's probability at the user's
  /// strength (local, no quota); a supplied database share is the fallback.
  double? get share => maiaProb ?? dbShare;

  PlanCandidate copyWith({
    String? name,
    String? eco,
    double? dbShare,
    int? dbGames,
    double? maiaProb,
    int? evalCp,
    int? evalDepth,
    String? evalSource,
    double? ownShare,
    int? ownGames,
    bool? inChapters,
    int? bookBelow,
  }) => PlanCandidate(
    san: san,
    name: name ?? this.name,
    eco: eco ?? this.eco,
    dbShare: dbShare ?? this.dbShare,
    dbGames: dbGames ?? this.dbGames,
    maiaProb: maiaProb ?? this.maiaProb,
    evalCp: evalCp ?? this.evalCp,
    evalDepth: evalDepth ?? this.evalDepth,
    evalSource: evalSource ?? this.evalSource,
    ownShare: ownShare ?? this.ownShare,
    ownGames: ownGames ?? this.ownGames,
    inChapters: inChapters ?? this.inChapters,
    bookBelow: bookBelow ?? this.bookBelow,
  );
}

enum PlanStepKind {
  /// The user is to move and the book forks: ask which move(s) they play.
  ourMove,

  /// The opponent is to move at a tabiya: confirm which replies get their
  /// own chapter.
  theirMove,

  /// The walk would stop here (book ran out, no fork): show the position and
  /// ask — generate from here, or keep setting up?
  confirmLeaf,

  /// This move order reaches a position already set up by another: skip it
  /// (that line covers it) or set it up separately?
  transposition,
}

/// A position the walk stopped at to ask something.
class PlanStep {
  final List<String> moves;
  final PlanStepKind kind;
  final String fen;

  /// Ranked candidates; empty while loading.
  final List<PlanCandidate> candidates;
  final bool loading;

  /// The book's name for this position, for the card title.
  final String? positionName;

  /// Pre-selected SANs: what the user already plays here (their chapters or
  /// their games) for our moves; replies at/above the chapter share for
  /// theirs.
  final Set<String> preselected;

  /// Probability of reaching this position from the walk's root (1.0 at the
  /// root; each opponent reply descended into multiplies by its share).
  final double reachProb;

  /// For [PlanStepKind.transposition]: the move order that got here first.
  final List<String>? transposesTo;

  const PlanStep({
    required this.moves,
    required this.kind,
    required this.fen,
    required this.candidates,
    required this.loading,
    required this.positionName,
    required this.preselected,
    this.reachProb = 1.0,
    this.transposesTo,
  });

  PlanStep copyWith({
    List<PlanCandidate>? candidates,
    bool? loading,
    Set<String>? preselected,
  }) => PlanStep(
    moves: moves,
    kind: kind,
    fen: fen,
    candidates: candidates ?? this.candidates,
    loading: loading ?? this.loading,
    positionName: positionName,
    preselected: preselected ?? this.preselected,
    reachProb: reachProb,
    transposesTo: transposesTo,
  );
}

/// One place the engine starts building from, inside a chapter.
class PlanBuildPoint {
  /// SAN path from the start position to the build's root.
  final List<String> moves;

  /// Opponent replies at the root owned by sibling build points (SAN), so
  /// two builds never fill the same lines.
  final List<String> excludeReplies;

  /// Why the walk stopped here, in words.
  final String reason;

  const PlanBuildPoint({
    required this.moves,
    this.excludeReplies = const [],
    this.reason = '',
  });

  bool get isSidelines => excludeReplies.isNotEmpty;
}

/// One chapter to create: an opening *system* — a London chapter, a QGD
/// chapter — holding every line the walk set up inside it. Chapters are cut
/// where the probability mass splits into a differently named system, not
/// at every reply; inside, each set-up line is its own [PlanBuildPoint].
class PlanChapter {
  String name;

  /// The opening family this chapter is: the book name before its first ':'
  /// ("Queen's Gambit Declined", "London System").
  final String family;

  /// Path to the position where this chapter branched off.
  final List<String> moves;

  final List<PlanBuildPoint> points;

  PlanChapter({
    required this.name,
    required this.family,
    required this.moves,
    List<PlanBuildPoint>? points,
  }) : points = points ?? [];

  PlanChapter copy() => PlanChapter(
    name: name,
    family: family,
    moves: List.of(moves),
    points: List.of(points),
  );

  /// Every path the engine will build from.
  Iterable<List<String>> get buildPaths => points.map((p) => p.moves);
}

/// The finished plan.
class RepertoirePlan {
  final bool isWhite;
  final int elo;
  final double minShare;
  final List<PlanChapter> chapters;

  const RepertoirePlan({
    required this.isWhite,
    required this.elo,
    required this.minShare,
    required this.chapters,
  });
}
