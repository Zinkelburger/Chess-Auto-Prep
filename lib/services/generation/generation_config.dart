/// Configuration and output types for repertoire generation.
library;

import 'dart:convert';

import '../../constants/engine_defaults.dart';
import '../../models/build_tree_node.dart';
import '../../utils/system_info.dart';
import 'export/move_annotation.dart';
import 'skeleton_plan.dart';

export 'skeleton_plan.dart' show SkeletonPlan;
export 'export/move_annotation.dart' show MoveAnnotationDetail;

// ── Selection mode ──────────────────────────────────────────────────────

/// Which value the argmax at our-move nodes ranks by.  These are
/// different objectives, not presets: none of them rewrites another knob.
/// Preferences on top of the objective (novelties, opponent mistakes, a
/// natural move, a preferred setup) are weights and tolerances of their own.
enum SelectionMode { expectimax, engineOnly, dbWinRateOnly }

// ── Tree build algorithm mode ───────────────────────────────────────────

/// Fundamentally different tree-building algorithms (not parameter presets).
enum BuildMode {
  /// Stockfish MultiPV + Maia/Lichess opponent moves + expectimax (default).
  stockfishExpectimax,

  /// Top-N Maia moves for our side, DB evals only, stop on DB miss.
  maiaDbExplore,

  /// PGN database-seeded tree: parse game files, build frequency map,
  /// then BFS with eval enrichment — matches C `--build-mode db-explorer`.
  dbExplorer,

  /// ChessDB mainline book: our move is whatever the database ranks best,
  /// their replies are master practice, and off master practice the line
  /// continues as a single mainline until the database runs out.
  ///
  /// No Maia, no expectimax, no practicality weighting — the tree has one
  /// child at every one of our nodes, so there is nothing for a valuation
  /// to choose between.  Stockfish is a fallback only, for positions no
  /// ChessDB source has ever seen.
  chessDbBook,
}

// ── Search algorithm (frontier discipline + pruning preset) ─────────────

/// How the Phase 1 frontier is ordered and how aggressively rare lines are
/// pruned.  Expectimax valuation (Phase 2) is identical in both — the
/// algorithm only shapes which nodes exist in the tree.
enum SearchAlgorithm {
  /// "Full": level-order BFS, every candidate at full MultiPV and the full
  /// eval window.  NOT literally exhaustive — the configured floors
  /// ([TreeBuildConfig.minProbability], [TreeBuildConfig.maxPly], the eval
  /// window, opponent fan-out caps) still apply; what it drops is the
  /// *extra* narrowing Fast applies to rarely-reached positions.
  pure,

  /// "Fast": best-first (highest reach-priority node expands next) plus
  /// pruning that spends less effort on rarely-reached positions: our-move
  /// alternatives below the priority floor are skipped, MultiPV and the
  /// eval-loss window shrink in cold subtrees, and opponent fan-out is
  /// capped harder.  The coverage floor ([TreeBuildConfig.coverMinProb])
  /// is always honored, so Fast never creates silent holes.
  ///
  /// The pruning is what makes it faster; the best-first *order* only pays
  /// off when the run stops early — which is what
  /// [TreeBuildConfig.timeBudgetMinutes] is for.  With no budget and no
  /// manual Stop, Fast and Pure expand the same node set minus the pruning.
  fast,
}

/// Default total engine thread budget; users can opt into more CPU.
int defaultEngineThreads() => kDefaultGenerationThreads;

/// Clamp [threads] to [1, logical core count].
int clampEngineThreads(int threads) {
  final cores = getLogicalCores();
  return threads.clamp(1, cores);
}

// ── Two-phase tree build config (matches C tree_builder) ────────────────

/// Configuration for the two-phase tree build algorithm.
///
/// Phase 1 builds a persistent tree with all evals.  Phase 2 computes
/// ease/expectimax and selects repertoire moves.
class TreeBuildConfig {
  final String startFen;
  final bool playAsWhite;

  // ── Traversal limits ──
  final double minProbability;
  final int maxPly;
  final int maxNodes;

  /// Wall-clock budget for the expansion phase, in minutes.  0 = no limit.
  /// When the budget runs out the frontier stops expanding, the coverage
  /// sweep still runs (so no line ends on an unanswered opponent move) and
  /// the tree stays resumable.  This is what makes Fast search *fast*:
  /// best-first order means the positions it did reach are the ones you are
  /// most likely to face.
  final int timeBudgetMinutes;

  // ── Frontier discipline + pruning preset ──
  /// Pure = exhaustive FIFO BFS; Fast = best-first expansion with
  /// priority-scaled pruning.  See [SearchAlgorithm].
  final SearchAlgorithm searchAlgorithm;

  /// Best-first frontier ordering (pop the highest search priority — reach
  /// probability × our-alternative discount — instead of FIFO level order).
  /// Makes the build an anytime algorithm: at any node budget the tree is
  /// concentrated on the likeliest opponent lines.
  bool get bestFirst => searchAlgorithm == SearchAlgorithm.fast;

  /// Priority multiplier applied to non-incumbent our-move candidates
  /// (the incumbent — best eval at expansion time — inherits the parent's
  /// priority unchanged).  Lower = spend less of the budget verifying
  /// alternatives, more on deepening the current repertoire spine.
  /// Only affects expansion order/depth, never expectimax or selection.
  final double ourAltDiscount;

  /// Fast only: our-move alternatives more than this many centipawns behind
  /// the incumbent stay as evaluated leaves — no subtree.  Selection still
  /// sees them (leaf value from the static eval) and the verification pass
  /// deep-checks whatever gets picked, so the insurance subtrees are only
  /// grown for alternatives close enough to plausibly win the argmax.
  /// 0 disables the gate.  Pure search, or 0 here, searches the worse-eval
  /// candidates too.
  final int fastAltGapCp;

  /// "Wide opening search": our-move nodes at or below this ply get the wide
  /// [rootMultipv] candidate floor, the full [maxEvalLossCp] window, and (in
  /// Fast) exemption from the [fastAltGapCp] alternative-subtree gate — so the
  /// first few of our moves are explored broadly in BOTH search algorithms
  /// before the priority-zone pruning narrows the deeper, rarely-reached
  /// lines.  Applies to Pure too (it widens the MultiPV floor Pure would
  /// otherwise cap at [ourMultipv] past the root).  0 keeps the legacy
  /// behavior where only the root (ply 0) gets the wide floor.
  final int openingWidthPlies;

  /// Dirichlet prior weight (λ, in virtual games) for smoothing DB opponent
  /// move frequencies with Maia's policy:
  ///   p = (count + λ·maiaP) / (N + λ)
  /// Replaces the hard DB→Maia fallback cliff at sparsely covered positions.
  /// 0 disables smoothing (raw frequencies + hard fallback).
  final double maiaPriorGames;

  // ── Coverage guarantee ──
  /// No-silent-holes floor: any opponent reply whose LOCAL (per-position)
  /// smoothed probability is at or above this value must have a repertoire
  /// answer, even when its reach probability falls below [minProbability] or
  /// the mass/children budgets are exhausted.  Such nodes get a coverage-only
  /// expansion (one evaluated answer, no subtree).  At the end of the build,
  /// any our-turn leaf still lacking an answer is either coverage-expanded
  /// (local prob ≥ floor) or removed from the tree so uncovered mass is
  /// honestly returned to the expectimax tail term.  0 disables the floor
  /// (legacy behavior: rare replies silently dropped).
  final double coverMinProb;

  // ── Final verification pass ──
  /// Re-evaluate every selected repertoire move at [resolvedVerifyDepth]
  /// after selection.  Moves whose deep eval loses more than [maxEvalLossCp]
  /// against the best deep sibling are demoted and selection re-runs, so the
  /// exported repertoire carries a depth guarantee instead of trusting the
  /// shallower build-time evals.
  final bool verifyFinal;

  /// Stockfish depth for the verification pass. 0 = auto
  /// (max(evalDepth + 6, 20)).
  final int verifyDepth;

  // ── Preferred setup (consistency bias) ──
  /// Space/comma-separated SAN moves of a system to play whenever sound
  /// (e.g. "Be3 Qd2 f3 O-O-O h4 Nh3" for the 150 Attack).  Legal setup
  /// moves are injected as candidates at our-move nodes, and selection
  /// prefers a setup move within [setupToleranceCp] of the best child
  /// eval.  Expectimax values are untouched — the bias only constrains
  /// the argmax, so when the opponent makes consistency expensive the
  /// eval guard deviates automatically.  Empty disables.
  final String setupMoves;

  /// Max centipawns a setup move may lose vs the best child eval and
  /// still be preferred by selection.
  final int setupToleranceCp;

  // ── Root reply exclusion (planned builds) ──
  /// Opponent replies (SAN) at the *root* position that this build must not
  /// expand. A planned repertoire cuts sibling chapters at an opponent
  /// tabiya — "QGD vs 3.Nc3", "QGD vs Catalan", "QGD sidelines" — and the
  /// sidelines chapter is rooted at the same position as its siblings, so
  /// it excludes the replies they own. Only the root is filtered; deeper
  /// transpositions are legitimately this chapter's business.
  final List<String> rootReplyExclude;

  /// Memorability tie-break: within this many centipawns of the best child
  /// eval, selection prefers the our-move with the highest own-side Maia
  /// probability — the move the user would naturally play anyway, which is
  /// cheaper to memorize.  Capped at [maxEvalLossCp]; 0 disables.
  final int memorabilityToleranceCp;

  // ── Skeleton plan (repertoire planning front door) ──
  /// The user's skeleton: pinned our-moves, transfer targets, and structure
  /// vetoes (see `skeleton_plan.dart` and `docs/REPERTOIRE_PLANNING.md`).
  /// Serialized as a JSON *string* ([skeletonPlanJson]) so the persisted
  /// config stays flat. Empty plan = the classic build with no steering.
  final SkeletonPlan skeletonPlan;

  // ── Build algorithm ──
  final BuildMode buildMode;

  // ── Engine ──
  final int evalDepth;

  /// Total Stockfish thread budget during tree build (0 = default, 1 = one core).
  /// Use [resolvedEngineThreads] for the clamped value.
  final int engineThreads;

  // ── Our-move MultiPV (constant at every depth, matches C invariant) ──
  final int ourMultipv;
  final int maxEvalLossCp;

  // ── Opponent-move selection (constant at every depth) ──
  final int oppMaxChildren;
  final double oppMassTarget;

  // ── Eval window pruning ──
  final int minEvalCp;
  final int maxEvalCp;
  final bool relativeEval;

  // The Lichess Explorer knobs that used to live here (useLichessDb,
  // useMasters, ratingRange, speeds, minGames, maiaOnly) are gone. The
  // Explorer fetch path is mothballed app-wide (`ProbabilityService` returns
  // null), so they were a no-op that silently fell back to Maia while the
  // form claimed real game frequencies were in use. Real human-practice data
  // reaches the tree through [BuildMode.dbExplorer] and a scanned PGN
  // database instead.

  // ── Maia ──
  final int maiaElo;
  final double maiaMinProb;

  /// Temperature reshaping the opponent Maia policy before truncation:
  /// p → p^(1/T), renormalized over the full policy.  T > 1 flattens the
  /// distribution (a sloppier, more diverse opponent pool), T < 1 sharpens
  /// it toward the most common reply.  1.0 is a no-op.  Only the full
  /// legal-move policy is renormalized — the truncated subset feeding the
  /// expectimax tail term stays raw as always.
  final double oppPolicyTemperature;

  // ── PGN export ──
  /// Plies of raw engine continuation appended to an exported line once the
  /// prepared part runs out, so a line that stopped at the depth limit ends
  /// somewhere a reader can see rather than mid-air. 0 turns it off.
  ///
  /// The appended moves are explicitly *not* repertoire: they carry a note
  /// in the PGN saying where preparation stopped, and nothing downstream
  /// treats them as prepared theory.
  final int engineTailPlies;

  /// Stockfish depth for that continuation. 0 = auto ([resolvedVerifyDepth],
  /// i.e. max(evalDepth + 6, 20)). It is deliberately deeper than the build's
  /// own [evalDepth]: the whole point is that the tail is a better look at
  /// the position than the truncated search that stopped there.
  final int engineTailDepth;

  // How big the repertoire is is no longer decided here.  A build exports
  // every line that teaches something new, in the order the greedy set
  // cover ranked them, and the size is chosen afterwards against a live
  // line count — see `LineSlice` and the Generate tab's slice card.  Asking
  // for a coverage share up front meant guessing before there was anything
  // to look at, and the guess was baked into the file.

  /// Export only the lines that run through a trap — a position where the
  /// opponent has a tempting move that loses material or the evaluation.
  /// The tree is built exactly as usual; this drops every extracted line
  /// that no detected trap is a prefix of, so the PGN is a trap collection
  /// rather than a repertoire.  Nothing is exported when no traps are found.
  final bool trapsOnly;

  /// Sort extracted lines by cumulative probability (most likely first).
  final bool rankLinesByImportance;

  // ── How different a line has to be to get its own entry ──
  // Set cover admits a line the moment it teaches one decision nothing else
  // teaches, which on a real build leaves a book where nine lines in ten are
  // a tail-only variant of another one.  These two are the bar it has to
  // clear as well; `LineDiversity` in `line_pruner.dart` is where they are
  // explained and measured.  Failing the bar does not lose the line — it is
  // written as a sideline off the line it parts from.

  /// Share of a line's decisions that must be new to the book.  0 admits
  /// anything that teaches one new decision, which is the old behaviour.
  final double lineMinNewShare;

  /// Largest decision-set Jaccard a line may share with any single line
  /// already kept.  1 disables the cap.
  final double lineMaxOverlap;

  /// Longest sideline a fold may write, in plies.  Beyond this the line is
  /// dropped rather than buried inside another one.
  final int lineMaxFoldPlies;

  /// How much per-move detail the exported PGN carries.  The pipeline
  /// computes eval, ease, naturalness and practical scores for every node
  /// anyway; this decides how much of it reaches the file.
  final MoveAnnotationDetail annotationDetail;

  // ── Course layout ──
  /// Group the exported lines into named chapters (one PGN game each) instead
  /// of writing a flat list.  Chapters are cut at the branch points where the
  /// repertoire actually divides and named from the bundled ECO book, which
  /// is what turns a search result into something a person can study.
  final bool organizeIntoChapters;

  /// Split a chapter whose line count exceeds this, descending to the next
  /// branch point.  Chessable-sized chapters are a few dozen lines.
  final int maxLinesPerChapter;

  /// Merge sibling chapters below this size back into their parent, so a
  /// rare sideline does not become a chapter of its own.
  final int minLinesPerChapter;

  /// Cut chapters by ECO code instead of by the tree's branch points.
  ///
  /// Branch-point cutting names chapters after where *this* repertoire
  /// divides, which is the right answer for a book about one opening. A book
  /// that spans the whole encyclopedia divides everywhere, and the reader is
  /// looking for a code — so the top-level cut follows the classification and
  /// branch-point cutting runs inside each code.
  final bool chaptersByEco;

  /// Model games appended as trailing chapters — real games by strong
  /// players that follow the repertoire out of the opening.  Requires a game
  /// database (DB Explorer); 0 disables.
  final int modelGameCount;

  /// Rating floor for a game to qualify as a model game.  Separate from
  /// [minElo], which governs the whole frequency scan: a repertoire built
  /// from club games should still illustrate itself with master play.
  final int modelGameMinElo;

  /// After an opponent move leaves us winning, the build stops — there is
  /// nothing left to prepare.  With this on, the engine is asked how the
  /// position is actually won and the answer is written as a variation on
  /// that move, so the export shows why the move loses instead of ending.
  final bool refutationLines;

  /// Along every exported line, ask what a human would play that the book
  /// leaves out — the natural move we pass over, the try the opponent should
  /// avoid — and write the engine's answer to it as a variation.  Costs one
  /// engine search per candidate, so it runs after the build and is capped.
  final bool alternativeLines;

  // ── Expectimax / repertoire selection ──
  final SelectionMode selectionMode;
  final double leafConfidence;

  /// Novelty boost at our-move nodes, 0–100.  Scales a candidate's value by
  /// `1 + w × rarity` inside the eval-loss window; the stored expectimax
  /// values are untouched.  0 = off.
  final int noveltyWeight;

  // ── DB Explorer (PGN frequency seeding) ──
  final List<String> pgnFilePaths;
  final int dbMinGames;

  // ── Master games (TWIC) ──
  /// Consult the local master-games database when it has games: opponent
  /// replies come from titled-player practice (blended with Maia), model
  /// games are real master games along the line, and a repertoire move that
  /// beats what masters actually played is annotated "improves on … in
  /// `<game>`".  Has no effect until the database is downloaded.
  final bool useMasterGames;

  /// When [useMasterGames] is on but the database is empty, download it
  /// (The Week in Chess) before the build starts instead of quietly building
  /// without master practice.  The wait is offered with an escape hatch —
  /// see `GenerationSessionController.skipMasterGamesDownload` — and does
  /// nothing once the database has games.
  final bool downloadMasterGamesIfMissing;

  /// A position counts as *master practice* when the book holds at least
  /// this many games from it.  Below that a position is treated as off-book:
  /// its replies come from Maia alone, it gets no depth bonus, and our-move
  /// injection ignores it.
  final int masterMinGames;

  /// Search-order weight for master practice: a position masters have played
  /// is expanded before an equally-likely position none has.  The frontier is
  /// otherwise ordered on reach probability alone, which spends the node
  /// budget on whatever is *likely* rather than on what is *known* — under a
  /// time budget that is what decides which lines exist at all.
  ///
  /// Applied as `1 + weight * ln(1 + games)`, so the curve is generous at the
  /// bottom (2 games already earns a boost, which is the point — a line two
  /// masters chose is worth evaluating) and flattens at the top instead of
  /// letting a 400-game main line crowd out everything else.  0 disables it
  /// and restores pure reach-probability ordering.
  final double masterPriorityWeight;

  /// How many plies past [maxPly] a line may run while each position along
  /// it is still master practice.  Book lines are the lines worth knowing
  /// deeper; a Maia-only sideline stops at [maxPly] as before.  The book is
  /// indexed to move 15, which bounds the bonus naturally.  0 disables.
  final int masterDepthBonusPlies;

  /// Master-book games that make a reply immune to the probability floor.
  ///
  /// The floor ([maiaMinProb]) exists to keep Maia policy noise out of the
  /// tree, where a 4% entry really is noise. A move with a thousand recorded
  /// master games is not noise at 4%, and gating both on the same number is
  /// how the Four Pawns Attack (1159 games, 4.2% after 4...d6) came to be
  /// dropped from a King's Indian book with no chess judgement involved at
  /// all. Recorded practice is evidence of a different kind from a policy
  /// head's opinion, so it gets its own threshold, counted in games.
  ///
  /// This exempts a move from the *probability* floor only. The fan-out caps
  /// ([oppMaxChildren], [oppMassTarget]) still bind, except at the root —
  /// see [NodeExpander]. 0 disables the exemption.
  final int masterMinMoveGames;

  /// Opponent fan-out cap at off-book positions when a master book is in
  /// use (0 = same as [oppMaxChildren]).  Where no master has been, wide
  /// fan-out buys breadth nobody plays; narrowing it here spends the node
  /// budget on depth in the lines that are practice.  The coverage floor
  /// ([coverMinProb]) still bypasses it, so a likely reply is never dropped.
  final int offBookOppMaxChildren;

  // ── ChessDB mainline book ([BuildMode.chessDbBook]) ──

  /// How deep the off-book mainline tail runs, in plies.
  ///
  /// [maxPly] caps *branching* and nothing else: it is where the book stops
  /// answering new opponent choices and follows a single line.  Once a line
  /// has stopped branching — past that depth, or past master practice,
  /// whichever comes first — it costs one node per ply instead of a fan-out,
  /// so stopping it at the branching depth would cut off exactly the deepest
  /// theory the book exists to carry.  Every line therefore runs to this cap
  /// instead, or until ChessDB runs out, whichever comes first.  Values below
  /// [maxPly] are ignored.
  final int bookTailMaxPly;

  /// Whether the engine finishes a line ChessDB has stopped answering
  /// ([BuildMode.chessDbBook] only).
  ///
  /// Off by default, which makes a line end exactly where the database's
  /// knowledge does. On, a position no ChessDB source has seen is searched
  /// at [evalDepth] and the line continues — truer to "give me the whole
  /// line", but the deep tail is then Stockfish's book rather than ChessDB's,
  /// and it is expensive: at depth 30 each such position costs seconds where
  /// a database hit costs a request, so a build with a wide unknown tail
  /// spends most of its wall clock in the engine and covers far less ground.
  final bool bookEngineFallback;

  /// Centipawn window inside which master practice breaks a tie between our
  /// candidate moves ([BuildMode.chessDbBook] only).
  ///
  /// 0 — the default — means only moves the database scores *exactly* equal
  /// are tied, and the more-played one wins.  Raising it trades a little
  /// objectivity for the better-known move; it is the one place in this mode
  /// where anything but the database's own ranking has a vote.
  final int bookTieBreakWindowCp;

  /// Prefer the candidate that leaves the opponent the *fewest* good
  /// replies: a reply counts as good within this many centipawns of the
  /// opponent's best.  0 — the default — is off.
  ///
  /// Two moves an engine scores level can differ a lot here — one leaves the
  /// opponent a single good answer, the other five — and the narrower one is
  /// the smaller book to learn.  Expectimax does not see this on its own: an
  /// opponent node is valued by where the human model's probability lands,
  /// not by how many moves hold, so a position with one obvious good reply
  /// scores like one with ten.
  ///
  /// Where the count comes from depends on the build:
  ///  * Expectimax and the other selectors read the tree — a candidate's
  ///    evaluated opponent children, compared with the best of them — and
  ///    apply the preference inside the [maxEvalLossCp] window, with the
  ///    mode's own value separating candidates that count the same
  ///    (`RepertoireSelector._applyReplyPreference`).
  ///  * The ChessDB book asks the database for each candidate tied inside
  ///    [bookTieBreakWindowCp], which counts *every* good reply, played or
  ///    not, at one lookup per candidate; master practice then separates
  ///    equal counts.
  final int replyWindowCp;

  /// Minimum engine gain (centipawns, for us) over the master move before a
  /// repertoire move is annotated as an improvement on a cited game.
  final int improvementMinGainCp;
  final double dbMinProb;
  final int minElo;

  // ── External eval sources (ChessDB local + API) ──
  final bool enableCdbDirect;
  final String cdbDirectPath;
  final bool cdbDirectReadAhead;
  final bool enableLocalChessDb;

  /// Consult the Lichess cloud-evaluation store, and where it lives.
  final bool enableLichessEvals;
  final String lichessEvalsPath;
  final String localChessDbPath;
  final bool enableChessDbApi;
  final int chessDbApiDailyQuota;

  final int chessDbApiConcurrency;
  final bool enableExtEvalSubtreeSkip;
  final int minAcceptableEvalDepth;

  const TreeBuildConfig({
    required this.startFen,
    required this.playAsWhite,
    this.minProbability = 0.0001,
    this.maxPly = 20,
    this.maxNodes = 0,
    this.timeBudgetMinutes = 0,
    this.searchAlgorithm = SearchAlgorithm.fast,
    this.ourAltDiscount = 0.25,
    this.fastAltGapCp = 30,
    this.openingWidthPlies = 3,
    this.maiaPriorGames = 30.0,
    this.coverMinProb = 0.05,
    this.verifyFinal = true,
    this.verifyDepth = 0,
    this.setupMoves = '',
    this.setupToleranceCp = 30,
    this.rootReplyExclude = const [],
    this.memorabilityToleranceCp = 0,
    this.skeletonPlan = const SkeletonPlan(),
    this.buildMode = BuildMode.stockfishExpectimax,
    this.evalDepth = kDefaultGenerationEvalDepth,
    this.engineThreads = 0,
    this.ourMultipv = 4,
    this.maxEvalLossCp = 50,
    this.oppMaxChildren = 4,
    this.oppMassTarget = 0.80,
    this.minEvalCp = 0,
    this.maxEvalCp = 200,
    this.relativeEval = true,
    this.maiaElo = 2200,
    this.maiaMinProb = 0.05,
    this.oppPolicyTemperature = 1.0,
    this.engineTailPlies = 6,
    this.engineTailDepth = 0,
    this.trapsOnly = false,
    this.rankLinesByImportance = true,
    this.lineMinNewShare = 0.25,
    this.lineMaxOverlap = 0.7,
    this.lineMaxFoldPlies = 6,
    this.annotationDetail = MoveAnnotationDetail.full,
    this.organizeIntoChapters = true,
    this.maxLinesPerChapter = 40,
    this.minLinesPerChapter = 5,
    this.chaptersByEco = false,
    this.modelGameCount = 6,
    this.modelGameMinElo = 2200,
    this.refutationLines = true,
    this.alternativeLines = true,
    this.selectionMode = SelectionMode.expectimax,
    this.leafConfidence = 1.0,
    this.noveltyWeight = 0,
    this.pgnFilePaths = const [],
    this.dbMinGames = 5,
    this.useMasterGames = true,
    this.downloadMasterGamesIfMissing = true,
    this.masterMinGames = 3,
    this.masterMinMoveGames = 10,
    this.masterDepthBonusPlies = 10,
    this.masterPriorityWeight = 0.35,
    this.offBookOppMaxChildren = 2,
    this.bookTailMaxPly = 40,
    this.bookEngineFallback = false,
    this.bookTieBreakWindowCp = 0,
    this.replyWindowCp = 0,
    this.improvementMinGainCp = 40,
    this.dbMinProb = 0.05,
    this.minElo = 0,
    this.enableCdbDirect = false,
    this.cdbDirectPath = '',
    this.cdbDirectReadAhead = false,
    this.enableLocalChessDb = false,
    this.enableLichessEvals = false,
    this.lichessEvalsPath = '',
    this.localChessDbPath = '',
    this.enableChessDbApi = false,
    this.chessDbApiDailyQuota = 5000,
    this.chessDbApiConcurrency = 2,
    this.enableExtEvalSubtreeSkip = true,
    this.minAcceptableEvalDepth = 0,
  });

  factory TreeBuildConfig.fromJson(
    Map<String, dynamic> json, {
    required String startFen,
  }) {
    return TreeBuildConfig(
      startFen: startFen,
      playAsWhite: json['play_as_white'] as bool? ?? true,
      minProbability: (json['min_probability'] as num?)?.toDouble() ?? 0.0001,
      maxPly: (json['max_depth'] as num?)?.toInt() ?? 20,
      maxNodes: (json['max_nodes'] as num?)?.toInt() ?? 0,
      timeBudgetMinutes: (json['time_budget_minutes'] as num?)?.toInt() ?? 0,
      searchAlgorithm: _parseSearchAlgorithm(
        json['search_algorithm'] as String?,
        legacyBestFirst: json['best_first'] as bool?,
      ),
      ourAltDiscount: (json['our_alt_discount'] as num?)?.toDouble() ?? 0.25,
      fastAltGapCp: (json['fast_alt_gap_cp'] as num?)?.toInt() ?? 30,
      openingWidthPlies: (json['opening_width_plies'] as num?)?.toInt() ?? 3,
      maiaPriorGames: (json['maia_prior_games'] as num?)?.toDouble() ?? 30.0,
      coverMinProb: (json['cover_min_prob'] as num?)?.toDouble() ?? 0.05,
      verifyFinal: json['verify_final'] as bool? ?? true,
      verifyDepth: (json['verify_depth'] as num?)?.toInt() ?? 0,
      setupMoves: json['setup_moves'] as String? ?? '',
      rootReplyExclude:
          (json['root_reply_exclude'] as List?)?.cast<String>() ?? const [],
      setupToleranceCp: (json['setup_tolerance_cp'] as num?)?.toInt() ?? 30,
      skeletonPlan: _decodeSkeleton(json['skeleton_plan']),
      memorabilityToleranceCp:
          (json['memorability_tolerance_cp'] as num?)?.toInt() ?? 0,
      buildMode: _parseBuildMode(json['build_mode'] as String?),
      evalDepth:
          (json['eval_depth'] as num?)?.toInt() ?? kDefaultGenerationEvalDepth,
      engineThreads: (json['engine_threads'] as num?)?.toInt() ?? 0,
      ourMultipv: (json['our_multipv'] as num?)?.toInt() ?? 4,
      maxEvalLossCp: (json['max_eval_loss_cp'] as num?)?.toInt() ?? 50,
      oppMaxChildren: (json['opp_max_children'] as num?)?.toInt() ?? 4,
      oppMassTarget: (json['opp_mass_target'] as num?)?.toDouble() ?? 0.80,
      minEvalCp: (json['min_eval_cp'] as num?)?.toInt() ?? 0,
      maxEvalCp: (json['max_eval_cp'] as num?)?.toInt() ?? 200,
      relativeEval: json['relative_eval'] as bool? ?? true,
      maiaElo: (json['maia_elo'] as num?)?.toInt() ?? 2200,
      maiaMinProb: (json['maia_min_prob'] as num?)?.toDouble() ?? 0.05,
      oppPolicyTemperature:
          (json['opp_policy_temperature'] as num?)?.toDouble() ?? 1.0,
      engineTailPlies: (json['engine_tail_plies'] as num?)?.toInt() ?? 6,
      engineTailDepth: (json['engine_tail_depth'] as num?)?.toInt() ?? 0,
      trapsOnly: json['traps_only'] as bool? ?? false,
      rankLinesByImportance: json['rank_lines_by_importance'] as bool? ?? true,
      lineMinNewShare: (json['line_min_new_share'] as num?)?.toDouble() ?? 0.25,
      lineMaxOverlap: (json['line_max_overlap'] as num?)?.toDouble() ?? 0.7,
      lineMaxFoldPlies: json['line_max_fold_plies'] as int? ?? 6,
      annotationDetail: _parseAnnotationDetail(json),
      organizeIntoChapters: json['organize_into_chapters'] as bool? ?? true,
      maxLinesPerChapter:
          (json['max_lines_per_chapter'] as num?)?.toInt() ?? 40,
      minLinesPerChapter: (json['min_lines_per_chapter'] as num?)?.toInt() ?? 5,
      chaptersByEco: json['chapters_by_eco'] as bool? ?? false,
      modelGameCount: (json['model_game_count'] as num?)?.toInt() ?? 6,
      modelGameMinElo: (json['model_game_min_elo'] as num?)?.toInt() ?? 2200,
      refutationLines: json['refutation_lines'] as bool? ?? true,
      alternativeLines: json['alternative_lines'] as bool? ?? true,
      selectionMode: _parseSelectionMode(json['selection_mode'] as String?),
      leafConfidence: (json['leaf_confidence'] as num?)?.toDouble() ?? 1.0,
      noveltyWeight: (json['novelty_weight'] as num?)?.toInt() ?? 0,
      pgnFilePaths:
          (json['pgn_file_paths'] as List<dynamic>?)?.cast<String>() ??
          const [],
      dbMinGames: (json['db_min_games'] as num?)?.toInt() ?? 5,
      useMasterGames: json['use_master_games'] as bool? ?? true,
      downloadMasterGamesIfMissing:
          json['download_master_games_if_missing'] as bool? ?? true,
      masterMinGames: (json['master_min_games'] as num?)?.toInt() ?? 3,
      masterMinMoveGames:
          (json['master_min_move_games'] as num?)?.toInt() ?? 10,
      masterPriorityWeight:
          (json['master_priority_weight'] as num?)?.toDouble() ?? 0.35,
      masterDepthBonusPlies:
          (json['master_depth_bonus_plies'] as num?)?.toInt() ?? 10,
      offBookOppMaxChildren:
          (json['off_book_opp_max_children'] as num?)?.toInt() ?? 2,
      improvementMinGainCp:
          (json['improvement_min_gain_cp'] as num?)?.toInt() ?? 40,
      dbMinProb: (json['db_min_prob'] as num?)?.toDouble() ?? 0.05,
      minElo: (json['min_elo'] as num?)?.toInt() ?? 0,
      enableCdbDirect: json['enable_cdbdirect'] as bool? ?? false,
      cdbDirectPath: json['cdbdirect_path'] as String? ?? '',
      cdbDirectReadAhead: json['cdbdirect_read_ahead'] as bool? ?? false,
      enableLocalChessDb: json['enable_local_chessdb'] as bool? ?? false,
      enableLichessEvals: json['enable_lichess_evals'] as bool? ?? false,
      lichessEvalsPath: json['lichess_evals_path'] as String? ?? '',
      localChessDbPath: json['local_chessdb_path'] as String? ?? '',
      enableChessDbApi: json['enable_chessdb_api'] as bool? ?? false,
      chessDbApiDailyQuota:
          (json['chessdb_api_daily_quota'] as num?)?.toInt() ?? 5000,
      chessDbApiConcurrency:
          (json['chessdb_api_concurrency'] as num?)?.toInt() ?? 2,
      enableExtEvalSubtreeSkip:
          json['enable_ext_eval_subtree_skip'] as bool? ?? true,
      minAcceptableEvalDepth:
          (json['min_acceptable_eval_depth'] as num?)?.toInt() ?? 0,
      bookTailMaxPly: (json['book_tail_max_ply'] as num?)?.toInt() ?? 40,
      bookEngineFallback: json['book_engine_fallback'] as bool? ?? false,
      bookTieBreakWindowCp:
          (json['book_tie_break_window_cp'] as num?)?.toInt() ?? 0,
      replyWindowCp: (json['reply_window_cp'] as num?)?.toInt() ?? 0,
    );
  }

  /// Whether this build uses Stockfish during BFS tree construction.
  /// DB Explorer defers engine startup to the eval enrichment phase.
  ///
  /// The ChessDB book counts only when [bookEngineFallback] is on — its moves
  /// come from the database, and the engine is there purely as a floor under
  /// positions the database has never seen. With the floor off it needs no
  /// engine at all.
  bool get usesStockfish =>
      buildMode == BuildMode.stockfishExpectimax ||
      (isChessDbBook && bookEngineFallback);

  /// Whether the expander resolves an our-move node's own eval, so the build
  /// loop must not resolve one first.
  ///
  /// Stockfish MultiPV and the ChessDB book both learn a position's eval from
  /// the very call that gives them its moves. Pre-evaluating would pay for
  /// that twice — and for the book, "twice" is a second network request per
  /// position, which is the difference between a build that fits in a quota
  /// and one that does not.
  bool get expanderSuppliesOurMoveEval =>
      buildMode == BuildMode.stockfishExpectimax || isChessDbBook;

  /// Whether the build needs Stockfish at any phase (build or enrichment).
  bool get needsStockfish => usesStockfish || buildMode == BuildMode.dbExplorer;

  /// True while building a single-move-per-side mainline book.
  bool get isChessDbBook => buildMode == BuildMode.chessDbBook;

  /// Whether Phase 2.5 has anything to re-check.
  ///
  /// The ChessDB book never verifies. Its moves are the database's, and
  /// re-ranking them by a local search at verification depth would quietly
  /// substitute Stockfish's opinion for ChessDB's — which is the one thing
  /// this mode exists not to do.
  bool get runsVerification => verifyFinal && needsStockfish && !isChessDbBook;

  /// Ply cap for the off-book mainline tail, never below [maxPly].
  int get resolvedBookTailMaxPly =>
      bookTailMaxPly > maxPly ? bookTailMaxPly : maxPly;

  /// Clamped engine thread count (defaults to one).
  int get resolvedEngineThreads => engineThreads > 0
      ? clampEngineThreads(engineThreads)
      : defaultEngineThreads();

  /// Short label for the active build algorithm.
  String get buildModeLabel => switch (buildMode) {
    BuildMode.stockfishExpectimax => 'Stockfish + expectimax',
    BuildMode.maiaDbExplore => 'Maia DB explore',
    BuildMode.dbExplorer => 'DB Explorer',
    BuildMode.chessDbBook => 'ChessDB mainline book',
  };

  /// Compact one-line summary for Jobs panel and status displays.
  String get summaryLabel {
    final parts = <String>[
      buildModeLabel,
      searchAlgorithm == SearchAlgorithm.pure ? 'Pure' : 'Fast',
      '${maxPly}ply',
    ];
    if (usesStockfish) {
      parts.add('SF d$evalDepth');
    }
    if (buildMode == BuildMode.dbExplorer && pgnFilePaths.isNotEmpty) {
      parts.add('${pgnFilePaths.length} PGN');
    }
    parts.add('Maia $maiaElo');
    if (organizeIntoChapters) {
      parts.add(chaptersByEco ? 'ECO chapters' : 'chapters');
    }
    return parts.join(' · ');
  }

  /// Engine resource summary when Stockfish is used.
  String get engineResourceLabel =>
      '$resolvedEngineThreads thread${resolvedEngineThreads == 1 ? '' : 's'}';

  /// Verification depth with the 0 = auto rule applied.
  int get resolvedVerifyDepth =>
      verifyDepth > 0 ? verifyDepth : (evalDepth + 6 < 20 ? 20 : evalDepth + 6);

  /// Depth actually used for the engine tail; see [engineTailDepth].
  int get resolvedEngineTailDepth =>
      engineTailDepth > 0 ? engineTailDepth : resolvedVerifyDepth;

  /// Minimum depth required from external eval sources.
  int get effectiveMinEvalDepth =>
      minAcceptableEvalDepth > 0 ? minAcceptableEvalDepth : evalDepth;

  /// Whole games the frequency scan keeps, to choose model games from.
  ///
  /// Far larger than [modelGameCount] on purpose: retention ranks by rating,
  /// but selection needs games that *follow this repertoire*, and most of a
  /// database's strongest games never enter the opening at all.  0 when model
  /// games are off, which makes the scan skip retention entirely.
  int get retainedGameCount =>
      modelGameCount <= 0 ? 0 : (modelGameCount * 256).clamp(512, 4096);

  // ── Fast Expectimax priority-scaled pruning ──
  //
  // Fast splits the tree into hot / warm / cold zones by reach priority.
  // Hot nodes (opponent reaches them often) get the full configured search;
  // warm ones lose one MultiPV line; cold ones (rarely reached — expectimax
  // weighs them by reach probability, so eval noise there barely moves the
  // root value) get minimum MultiPV, a halved eval-loss window, and halved
  // opponent fan-out.  Pure ignores the zones entirely.

  /// Reach-priority floor of the hot zone (full configured search).
  static const double fastWarmPriority = 0.02;

  /// Reach-priority floor of the warm zone; below this is cold.
  static const double fastColdPriority = 0.002;

  /// Fast only: cap on how many gap-qualifying our-move alternatives get a
  /// subtree per node (the incumbent always does).  One strong alternative
  /// is the insurance against a wrong incumbent judgment; a second covers
  /// near-ties.  Beyond that, alternatives stay evaluated leaves.
  static const int fastMaxExpandedAlts = 2;

  /// Root nodes always get at least this wide a MultiPV sweep regardless of
  /// the configured [ourMultipv] — every line in the repertoire descends
  /// from the root, so a narrow first fan-out can never be recovered later.
  static const int rootMultipvFloor = 10;

  /// Hard cap on candidate our-moves considered at a single node, whatever
  /// the source (MultiPV lines, Maia policy entries).  Bounds engine work
  /// and keeps pathological policy outputs from exploding the tree.
  static const int maxOurCandidates = 16;

  /// Our-move MultiPV at a node with reach priority [priority].
  int effectiveMultipv(double priority) {
    if (searchAlgorithm == SearchAlgorithm.pure) return ourMultipv;
    if (priority >= fastWarmPriority) return ourMultipv;
    final reduced = priority >= fastColdPriority ? ourMultipv - 1 : 2;
    return reduced.clamp(2, ourMultipv < 2 ? 2 : ourMultipv);
  }

  /// Our-move MultiPV at the root: the configured width, floored at
  /// [rootMultipvFloor].
  int get rootMultipv =>
      ourMultipv >= rootMultipvFloor ? ourMultipv : rootMultipvFloor;

  /// Whether [ply] is inside the widened opening band — the feature is on
  /// ([openingWidthPlies] > 0) and [ply] is at or below it.  Callers use this
  /// to grant the wide MultiPV floor / full eval window and, in Fast, to
  /// exempt our-move alternatives from the subtree gate.  The root (ply 0)
  /// always gets the wide floor regardless (via [rootMultipv]); this only
  /// governs the *extension* past the root and the gate exemption.
  bool widensOpeningAtPly(int ply) =>
      openingWidthPlies > 0 && ply <= openingWidthPlies;

  /// Max centipawns an our-move candidate may lose vs the best sibling and
  /// still enter the tree, at reach priority [priority].
  int effectiveMaxEvalLossCp(double priority) {
    if (searchAlgorithm == SearchAlgorithm.pure) return maxEvalLossCp;
    if (priority >= fastColdPriority) return maxEvalLossCp;
    return (maxEvalLossCp / 2).round();
  }

  /// Opponent fan-out cap at reach priority [priority] (0 = unlimited).
  /// Coverage-floor replies bypass this cap at the call sites, so the
  /// no-silent-holes guarantee survives Fast pruning.
  int effectiveOppMaxChildren(double priority) {
    if (searchAlgorithm == SearchAlgorithm.pure) return oppMaxChildren;
    if (priority >= fastColdPriority) return oppMaxChildren;
    if (oppMaxChildren <= 0) return 3;
    return oppMaxChildren <= 4 ? 2 : oppMaxChildren ~/ 2;
  }

  /// Whether an our-move alternative sitting [gapCp] behind the incumbent
  /// gets a subtree, given [altsAlreadyExpanded] siblings already granted
  /// one.  See [fastAltGapCp]; the incumbent itself never passes through
  /// this gate.
  bool expandAlternative({
    required int gapCp,
    required int altsAlreadyExpanded,
  }) {
    if (searchAlgorithm == SearchAlgorithm.pure) return true;
    if (fastAltGapCp <= 0) return true;
    if (gapCp > fastAltGapCp) return false;
    return altsAlreadyExpanded < fastMaxExpandedAlts;
  }

  /// Short label for the frontier/pruning algorithm.
  String get searchAlgorithmLabel => switch (searchAlgorithm) {
    SearchAlgorithm.pure => 'Pure search',
    SearchAlgorithm.fast => 'Fast search',
  };

  /// Convert a white-perspective centipawn score to "our" perspective.
  int toOurPerspective(int whiteCp) => playAsWhite ? whiteCp : -whiteCp;

  /// Serialise to a JSON-compatible map for tree file metadata.
  ///
  /// **This map is a persisted format, not an internal detail.** It is written
  /// to three places that outlive the process and are read back later:
  ///
  ///  * `<repertoire>_tree.json` (see `tree_serialization.dart`)
  ///  * the partial-tree file a paused build resumes from — [fromJson] on
  ///    `tree.configSnapshot` is what restores the settings of a build started
  ///    days ago
  ///  * user-saved generation presets (`generation_presets.dart`)
  ///
  /// So the shape must stay **flat and snake_case**, and keys must keep their
  /// meaning. Grouping these ~70 fields into nested sub-config objects is
  /// tempting for readability — the fields are already grouped by the section
  /// comments above — but doing so naively changes this map and silently
  /// breaks every existing preset and every resumable build on disk. If it is
  /// ever worth doing, nest the Dart API only and keep this method emitting
  /// the flat keys, or add a version field and migrate.
  ///
  /// Adding a key is safe: [fromJson] defaults every field, so older files
  /// still load. Renaming or removing one is not — see `best_first` below,
  /// kept purely so older builds can still read newer trees.
  Map<String, dynamic> toJson() => {
    'play_as_white': playAsWhite,
    'min_probability': minProbability,
    'max_depth': maxPly,
    'max_nodes': maxNodes,
    'time_budget_minutes': timeBudgetMinutes,
    'search_algorithm': searchAlgorithm.name,
    // Legacy key so older builds of the app can still read tree metadata.
    'best_first': bestFirst,
    'our_alt_discount': ourAltDiscount,
    'fast_alt_gap_cp': fastAltGapCp,
    'opening_width_plies': openingWidthPlies,
    'maia_prior_games': maiaPriorGames,
    'cover_min_prob': coverMinProb,
    'verify_final': verifyFinal,
    'verify_depth': verifyDepth,
    'setup_moves': setupMoves,
    'setup_tolerance_cp': setupToleranceCp,
    if (rootReplyExclude.isNotEmpty) 'root_reply_exclude': rootReplyExclude,
    'memorability_tolerance_cp': memorabilityToleranceCp,
    'skeleton_plan': _encodeSkeleton(skeletonPlan),
    'build_mode': buildMode.name,
    'eval_depth': evalDepth,
    'engine_threads': resolvedEngineThreads,
    'our_multipv': ourMultipv,
    'max_eval_loss_cp': maxEvalLossCp,
    'opp_max_children': oppMaxChildren,
    'opp_mass_target': oppMassTarget,
    'min_eval_cp': minEvalCp,
    'max_eval_cp': maxEvalCp,
    'relative_eval': relativeEval,
    'maia_elo': maiaElo,
    'maia_min_prob': maiaMinProb,
    'opp_policy_temperature': oppPolicyTemperature,
    'engine_tail_plies': engineTailPlies,
    'engine_tail_depth': engineTailDepth,
    'traps_only': trapsOnly,
    'rank_lines_by_importance': rankLinesByImportance,
    'line_min_new_share': lineMinNewShare,
    'line_max_overlap': lineMaxOverlap,
    'line_max_fold_plies': lineMaxFoldPlies,
    'annotation_detail': annotationDetail.name,
    // Legacy key so a build of the app predating [annotationDetail] can still
    // read this tree's metadata without losing the setting entirely.
    'annotate_move_probabilities': annotationDetail.emitsAnything,
    'organize_into_chapters': organizeIntoChapters,
    'max_lines_per_chapter': maxLinesPerChapter,
    'min_lines_per_chapter': minLinesPerChapter,
    'chapters_by_eco': chaptersByEco,
    'model_game_count': modelGameCount,
    'model_game_min_elo': modelGameMinElo,
    'refutation_lines': refutationLines,
    'alternative_lines': alternativeLines,
    'selection_mode': selectionMode.name,
    'leaf_confidence': leafConfidence,
    'novelty_weight': noveltyWeight,
    'pgn_file_paths': pgnFilePaths,
    'db_min_games': dbMinGames,
    'use_master_games': useMasterGames,
    'download_master_games_if_missing': downloadMasterGamesIfMissing,
    'master_min_games': masterMinGames,
    'master_min_move_games': masterMinMoveGames,
    'master_priority_weight': masterPriorityWeight,
    'master_depth_bonus_plies': masterDepthBonusPlies,
    'off_book_opp_max_children': offBookOppMaxChildren,
    'book_tail_max_ply': bookTailMaxPly,
    'book_engine_fallback': bookEngineFallback,
    'book_tie_break_window_cp': bookTieBreakWindowCp,
    'reply_window_cp': replyWindowCp,
    'improvement_min_gain_cp': improvementMinGainCp,
    'db_min_prob': dbMinProb,
    'min_elo': minElo,
    'enable_cdbdirect': enableCdbDirect,
    'cdbdirect_path': cdbDirectPath,
    'cdbdirect_read_ahead': cdbDirectReadAhead,
    'enable_local_chessdb': enableLocalChessDb,
    'enable_lichess_evals': enableLichessEvals,
    'lichess_evals_path': lichessEvalsPath,
    'local_chessdb_path': localChessDbPath,
    'enable_chessdb_api': enableChessDbApi,
    'chessdb_api_daily_quota': chessDbApiDailyQuota,
    'chessdb_api_concurrency': chessDbApiConcurrency,
    'enable_ext_eval_subtree_skip': enableExtEvalSubtreeSkip,
    'min_acceptable_eval_depth': minAcceptableEvalDepth,
  };

  /// The generation form's defaults for [playAsWhite]: the eval window is
  /// colour-aware because Black is objectively a little worse from move one,
  /// so a floor of 0 would throw away sound Black lines (and every gambit).
  /// Anything that seeds a build without going through the form — the
  /// planner's base config, presets — must start here, not at the bare
  /// constructor defaults.
  /// [relativeEval] is on by default, which makes [minEvalCp]/[maxEvalCp]
  /// offsets from the root's own eval rather than absolute scores — so these
  /// defaults are the same for both colours on purpose.
  ///
  /// They used to be colour-split (White 0/200, Black -100/100), which only
  /// made sense read as absolute evals: White starts a shade better, Black a
  /// shade worse. As offsets that split is meaningless, and the White floor
  /// of 0 was actively harmful — as an offset it says "never prepare a
  /// position even a centipawn worse than the one you started from", which
  /// deletes normal opening play and every gambit outright.
  factory TreeBuildConfig.formDefaults({
    required String startFen,
    required bool playAsWhite,
  }) => TreeBuildConfig(
    startFen: startFen,
    playAsWhite: playAsWhite,
    minEvalCp: -100,
    maxEvalCp: 200,
    // The form's declared default; the constructor's own is 50.
    maxEvalLossCp: 30,
  );

  /// The eval window actually applied to a tree built from [root]: with
  /// [relativeEval] the build shifts [minEvalCp]/[maxEvalCp] by the root
  /// eval (for us) once it is known.  Every post-build consumer of the
  /// window — repertoire selection, verification, snapshot export — must go
  /// through this too, or it judges nodes against the unshifted window and
  /// (for Black, whose root eval is negative) rejects the entire tree.
  ///
  /// This is what makes the window mean the same thing whatever position you
  /// hand the builder. A root at 0.00 and a root at +0.60 get windows 60cp
  /// apart in absolute terms and identical in relative ones, so "prepare
  /// down to a pawn worse than where this starts" is one setting rather than
  /// one per position.
  TreeBuildConfig anchoredToRoot(BuildTreeNode root) {
    if (!relativeEval || !root.hasEngineEval) return this;
    final rootEvalUs = root.evalForUs(playAsWhite);
    return copyWith(
      minEvalCp: minEvalCp + rootEvalUs,
      maxEvalCp: maxEvalCp + rootEvalUs,
    );
  }

  TreeBuildConfig copyWith({
    String? startFen,
    bool? playAsWhite,
    double? minProbability,
    int? maxPly,
    int? maxNodes,
    int? timeBudgetMinutes,
    SearchAlgorithm? searchAlgorithm,
    double? ourAltDiscount,
    int? fastAltGapCp,
    int? openingWidthPlies,
    double? maiaPriorGames,
    double? coverMinProb,
    bool? verifyFinal,
    int? verifyDepth,
    String? setupMoves,
    int? setupToleranceCp,
    List<String>? rootReplyExclude,
    int? memorabilityToleranceCp,
    SkeletonPlan? skeletonPlan,
    BuildMode? buildMode,
    int? evalDepth,
    int? engineThreads,
    int? ourMultipv,
    int? maxEvalLossCp,
    int? oppMaxChildren,
    double? oppMassTarget,
    int? minEvalCp,
    int? maxEvalCp,
    bool? relativeEval,
    int? maiaElo,
    double? maiaMinProb,
    double? oppPolicyTemperature,
    int? engineTailPlies,
    int? engineTailDepth,
    bool? trapsOnly,
    bool? rankLinesByImportance,
    double? lineMinNewShare,
    double? lineMaxOverlap,
    int? lineMaxFoldPlies,
    MoveAnnotationDetail? annotationDetail,
    bool? organizeIntoChapters,
    int? maxLinesPerChapter,
    int? minLinesPerChapter,
    bool? chaptersByEco,
    int? modelGameCount,
    int? modelGameMinElo,
    bool? refutationLines,
    bool? alternativeLines,
    SelectionMode? selectionMode,
    double? leafConfidence,
    int? noveltyWeight,
    List<String>? pgnFilePaths,
    int? dbMinGames,
    bool? useMasterGames,
    bool? downloadMasterGamesIfMissing,
    int? masterMinGames,
    int? masterMinMoveGames,
    double? masterPriorityWeight,
    int? masterDepthBonusPlies,
    int? offBookOppMaxChildren,
    int? bookTailMaxPly,
    bool? bookEngineFallback,
    int? bookTieBreakWindowCp,
    int? replyWindowCp,
    int? improvementMinGainCp,
    double? dbMinProb,
    int? minElo,
    bool? enableCdbDirect,
    String? cdbDirectPath,
    bool? cdbDirectReadAhead,
    bool? enableLocalChessDb,
    bool? enableLichessEvals,
    String? lichessEvalsPath,
    String? localChessDbPath,
    bool? enableChessDbApi,
    int? chessDbApiDailyQuota,
    int? chessDbApiConcurrency,
    bool? enableExtEvalSubtreeSkip,
    int? minAcceptableEvalDepth,
  }) {
    return TreeBuildConfig(
      startFen: startFen ?? this.startFen,
      playAsWhite: playAsWhite ?? this.playAsWhite,
      minProbability: minProbability ?? this.minProbability,
      maxPly: maxPly ?? this.maxPly,
      maxNodes: maxNodes ?? this.maxNodes,
      timeBudgetMinutes: timeBudgetMinutes ?? this.timeBudgetMinutes,
      searchAlgorithm: searchAlgorithm ?? this.searchAlgorithm,
      ourAltDiscount: ourAltDiscount ?? this.ourAltDiscount,
      fastAltGapCp: fastAltGapCp ?? this.fastAltGapCp,
      openingWidthPlies: openingWidthPlies ?? this.openingWidthPlies,
      maiaPriorGames: maiaPriorGames ?? this.maiaPriorGames,
      coverMinProb: coverMinProb ?? this.coverMinProb,
      verifyFinal: verifyFinal ?? this.verifyFinal,
      verifyDepth: verifyDepth ?? this.verifyDepth,
      setupMoves: setupMoves ?? this.setupMoves,
      setupToleranceCp: setupToleranceCp ?? this.setupToleranceCp,
      rootReplyExclude: rootReplyExclude ?? this.rootReplyExclude,
      memorabilityToleranceCp:
          memorabilityToleranceCp ?? this.memorabilityToleranceCp,
      skeletonPlan: skeletonPlan ?? this.skeletonPlan,
      buildMode: buildMode ?? this.buildMode,
      evalDepth: evalDepth ?? this.evalDepth,
      engineThreads: engineThreads ?? this.engineThreads,
      ourMultipv: ourMultipv ?? this.ourMultipv,
      maxEvalLossCp: maxEvalLossCp ?? this.maxEvalLossCp,
      oppMaxChildren: oppMaxChildren ?? this.oppMaxChildren,
      oppMassTarget: oppMassTarget ?? this.oppMassTarget,
      minEvalCp: minEvalCp ?? this.minEvalCp,
      maxEvalCp: maxEvalCp ?? this.maxEvalCp,
      relativeEval: relativeEval ?? this.relativeEval,
      maiaElo: maiaElo ?? this.maiaElo,
      maiaMinProb: maiaMinProb ?? this.maiaMinProb,
      oppPolicyTemperature: oppPolicyTemperature ?? this.oppPolicyTemperature,
      engineTailPlies: engineTailPlies ?? this.engineTailPlies,
      engineTailDepth: engineTailDepth ?? this.engineTailDepth,
      trapsOnly: trapsOnly ?? this.trapsOnly,
      rankLinesByImportance:
          rankLinesByImportance ?? this.rankLinesByImportance,
      lineMinNewShare: lineMinNewShare ?? this.lineMinNewShare,
      lineMaxOverlap: lineMaxOverlap ?? this.lineMaxOverlap,
      lineMaxFoldPlies: lineMaxFoldPlies ?? this.lineMaxFoldPlies,
      annotationDetail: annotationDetail ?? this.annotationDetail,
      organizeIntoChapters: organizeIntoChapters ?? this.organizeIntoChapters,
      maxLinesPerChapter: maxLinesPerChapter ?? this.maxLinesPerChapter,
      minLinesPerChapter: minLinesPerChapter ?? this.minLinesPerChapter,
      chaptersByEco: chaptersByEco ?? this.chaptersByEco,
      modelGameCount: modelGameCount ?? this.modelGameCount,
      modelGameMinElo: modelGameMinElo ?? this.modelGameMinElo,
      refutationLines: refutationLines ?? this.refutationLines,
      alternativeLines: alternativeLines ?? this.alternativeLines,
      selectionMode: selectionMode ?? this.selectionMode,
      leafConfidence: leafConfidence ?? this.leafConfidence,
      noveltyWeight: noveltyWeight ?? this.noveltyWeight,
      pgnFilePaths: pgnFilePaths ?? this.pgnFilePaths,
      dbMinGames: dbMinGames ?? this.dbMinGames,
      useMasterGames: useMasterGames ?? this.useMasterGames,
      downloadMasterGamesIfMissing:
          downloadMasterGamesIfMissing ?? this.downloadMasterGamesIfMissing,
      masterMinGames: masterMinGames ?? this.masterMinGames,
      masterMinMoveGames: masterMinMoveGames ?? this.masterMinMoveGames,
      masterPriorityWeight: masterPriorityWeight ?? this.masterPriorityWeight,
      masterDepthBonusPlies:
          masterDepthBonusPlies ?? this.masterDepthBonusPlies,
      offBookOppMaxChildren:
          offBookOppMaxChildren ?? this.offBookOppMaxChildren,
      bookTailMaxPly: bookTailMaxPly ?? this.bookTailMaxPly,
      bookEngineFallback: bookEngineFallback ?? this.bookEngineFallback,
      bookTieBreakWindowCp: bookTieBreakWindowCp ?? this.bookTieBreakWindowCp,
      replyWindowCp: replyWindowCp ?? this.replyWindowCp,
      improvementMinGainCp: improvementMinGainCp ?? this.improvementMinGainCp,
      dbMinProb: dbMinProb ?? this.dbMinProb,
      minElo: minElo ?? this.minElo,
      enableCdbDirect: enableCdbDirect ?? this.enableCdbDirect,
      cdbDirectPath: cdbDirectPath ?? this.cdbDirectPath,
      cdbDirectReadAhead: cdbDirectReadAhead ?? this.cdbDirectReadAhead,
      enableLocalChessDb: enableLocalChessDb ?? this.enableLocalChessDb,
      enableLichessEvals: enableLichessEvals ?? this.enableLichessEvals,
      lichessEvalsPath: lichessEvalsPath ?? this.lichessEvalsPath,
      localChessDbPath: localChessDbPath ?? this.localChessDbPath,
      enableChessDbApi: enableChessDbApi ?? this.enableChessDbApi,
      chessDbApiDailyQuota: chessDbApiDailyQuota ?? this.chessDbApiDailyQuota,
      chessDbApiConcurrency:
          chessDbApiConcurrency ?? this.chessDbApiConcurrency,
      enableExtEvalSubtreeSkip:
          enableExtEvalSubtreeSkip ?? this.enableExtEvalSubtreeSkip,
      minAcceptableEvalDepth:
          minAcceptableEvalDepth ?? this.minAcceptableEvalDepth,
    );
  }
}

SearchAlgorithm _parseSearchAlgorithm(String? value, {bool? legacyBestFirst}) {
  switch (value) {
    case 'pure':
      return SearchAlgorithm.pure;
    case 'fast':
      return SearchAlgorithm.fast;
  }
  // Configs written before the algorithm enum carry only best_first.
  if (legacyBestFirst == false) return SearchAlgorithm.pure;
  return SearchAlgorithm.fast;
}

/// Read the annotation level, falling back to the boolean pair this enum
/// replaced so presets and paused builds written before the change still load.
MoveAnnotationDetail _parseAnnotationDetail(Map<String, dynamic> json) {
  final name = json['annotation_detail'] as String?;
  if (name != null) return MoveAnnotationDetail.parse(name);
  final legacy = json['annotate_move_probabilities'] as bool?;
  if (legacy != null) {
    return MoveAnnotationDetail.fromLegacyFlags(annotate: legacy);
  }
  return MoveAnnotationDetail.full;
}

SelectionMode _parseSelectionMode(String? value) {
  switch (value) {
    case 'engineOnly':
      return SelectionMode.engineOnly;
    case 'dbWinRateOnly':
      return SelectionMode.dbWinRateOnly;
    default:
      return SelectionMode.expectimax;
  }
}

BuildMode _parseBuildMode(String? value) {
  switch (value) {
    case 'maiaDbExplore':
      return BuildMode.maiaDbExplore;
    case 'dbExplorer':
      return BuildMode.dbExplorer;
    case 'chessdb_book':
    case 'chessDbBook':
      return BuildMode.chessDbBook;
    default:
      return BuildMode.stockfishExpectimax;
  }
}

/// Encode a [SkeletonPlan] to a compact JSON string for the flat persisted
/// config. Empty plan → empty string so old readers and diffs stay clean.
String _encodeSkeleton(SkeletonPlan plan) =>
    plan.isEmpty ? '' : jsonEncode(plan.toJson());

/// Decode the `skeleton_plan` field, which may be a JSON string (current),
/// an already-decoded map (defensive), or absent/empty (→ empty plan).
SkeletonPlan _decodeSkeleton(Object? raw) {
  if (raw is Map<String, dynamic>) return SkeletonPlan.fromJson(raw);
  if (raw is String && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return SkeletonPlan.fromJson(decoded);
      }
    } catch (_) {
      // Corrupt blob → empty plan, never a wrong steer.
    }
  }
  return const SkeletonPlan();
}
