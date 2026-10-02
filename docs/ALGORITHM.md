# Pure expectimax contract

The Dart app and standalone C builder now use the same finite-horizon search
rules. `stockfishExpectimax` defaults to Pure. The optional
[Fast mode (four-ply lookahead)](ROLLING_SEARCH_AND_STUDY_LINES.md) uses the same local
model with approximate receding lookahead. Legacy Fast is retired; an old Fast
setting cannot activate heuristic pruning. This document defines Pure. Database exploration and the ChessDB mainline book remain
separate build sources.

## What is optimized

Choose a fixed repertoire side, a horizon H in half-moves from the supplied
root, an engine depth D, a maximum engine loss L in centipawns, and an opponent
policy. The default horizon is 4 plies. A larger horizon is exponentially more
expensive, even with just a few plies of preparation.

For each of our positions, enumerate **every legal move**, including all four
promotions. Evaluate each resulting position at depth D, using the repertoire
side's perspective. Retain every move whose evaluation is at least best − L.
These fixed-depth evaluations are immutable during expansion and backup.
Neither MultiPV width nor book popularity determines our candidate set.

For a complete tree, the recurrence is:

```
V(terminal) = 1 for our win, 0.5 for a draw, 0 for our loss
V(horizon)  = U(fixed-depth engine evaluation from our perspective)
V(our turn) = max V(child) over the admitted legal candidates
V(opponent) = sum policy(move | position) * V(child)
```

`U(cp) = 1 / (1 + exp(-0.00368208 * cp))`; packed mate scores with magnitude
above 9000 saturate to 0 or 1. This is a bounded **expected-score estimate**,
not a calibrated human win probability. The engine-loss constraint and leaf
utility depend on Stockfish's estimates. Search correctness does not prove
that those estimates, the opponent model, or the resulting move are objectively
correct chess. Stockfish itself remains a selective engine search.

The selected move uses exactly the same scorer as the maximizing backup.
Ties use engine evaluation, then UCI, then SAN. There are no novelty bonuses,
confidence blends, setup preferences, memorability bonuses, skeleton overrides,
reply-count preferences, or separate selection objectives.

## Opponent model

**Pure and Fast use Stockfish + Maia only.** Stockfish supplies position
estimates and the own-move loss constraint. Maia, at the displayed opponent
rating, supplies every opponent position's move probabilities. The legal
probabilities are normalized to sum to one; every positive-probability legal
reply remains in the search. There are no master counts, database fallbacks,
blends, probability-temperature changes, or hidden reply caps.

A missing or invalid Maia policy is an error. It never triggers a switch to a
game database. Master targeting and automatic downloads are unavailable for
Stockfish expectimax, including when an old preset enables their legacy flags.
The separate database build modes keep their own data workflows.

Saved trees record `opponent_book_source: "none"` and
`use_master_games: false`. C also records `maia_only: true`. Earlier trees
built with master probabilities cannot resume under this policy: start a fresh
build. Maia-only trees with `maia_policy_version: 1` can continue with the same position, rating,
evaluation settings and search method. Changes to the Maia or Stockfish model
versions can still affect newly evaluated positions. Older inference versions
require a fresh build; see [parallel search and Maia repeatability](PARALLEL_EXPECTIMAX.md).

## Chess state and draw convention

Each node retains its full path from the root. Identical piece placements can
have different remaining horizons, half-move clocks, or repetition histories;
Pure never borrows their backed-up values or merges their policies by FEN.
Starting a new search from an old Pure subtree rebuilds it with the new history.

Checkmate and stalemate are exact terminals. A terminal's value is chess, not
an estimate, but it still carries the score an engine would report there, so
the engine-loss window and the tie-break rank it against ordinary moves on one
scale: a checkmate is ±10000 from the mated side, which is what Stockfish's
`mate 0` packs to, and every draw is 0. Both builders write that score in
rather than asking the engine about a finished game. Insufficient material is
detected by the chess rules implementation. The model assumes both players immediately
claim a draw at the third occurrence or 100 half-moves, with checkmate taking
precedence. Repetition keys include side to move, castling rights, and legal
en-passant availability. History before the supplied root is unknown.

This is an explicit draw-claim convention, not full modeling of optional or
prospective draw claims. General dead positions beyond recognized insufficient
material, arbitrary game history before a FEN, and tablebase proofs are outside
this model. “100% correct chess” would require those inputs and additional rules.

## Completion, budgets, and resume

An expansion is committed atomically: first construct its complete action set
and evaluations, then attach it to the tree. Cancellation, time limits, or a
node budget never leave a partial probability distribution or partial legal
candidate enumeration. A node budget may leave some allowance unused when the
next complete expansion cannot fit. An in-flight engine evaluation may finish
after a requested time limit.

Unresolved frontier values are provisional. Their bounds are [0,1]; exact
terminals and evaluated horizon leaves have equal bounds. Bounds propagate by
max at our nodes and probability-weighted sum at opponent nodes. They bound
the defined finite model, not Stockfish error or real-world playing strength.
An incomplete result is labeled as such and does not claim its leader is solved.

Resume requires the same root, repertoire side, engine depth, engine-loss
limit, opponent rating, master-target setting, and book source. The horizon can
increase, but cannot shrink. Already expanded policies/evaluations are retained;
new frontier queries use the currently available engine/model/data. For a
uniform fresh comparison after changing any of these sources, start a new run.
Legacy heuristic trees must be rebuilt. Legacy files remain readable for review;
cyclic history-free value dependencies are rejected instead of iterated an
arbitrary number of times.

## Export and verification

Export follows the maximizing policy and every positive-probability opponent
reply. Pure paths are not folded by FEN or discarded by diversity, cumulative
probability, or absolute evaluation windows. Optional output products such as
trap-only collections and extra explanatory variations remain output choices;
they are not the tree's optimized policy. Engine tails are disabled for Pure.

There is no separate deep-verification pass for Pure. To strengthen evaluation,
rebuild at the desired engine depth, so all legal moves are admitted or rejected
at that depth. The legacy verifier re-evaluates its entire saved tree, commits
only a completed pass, and always recomputes values and selection. It can only
check saved candidates; it cannot recover moves a legacy build omitted.

## Implementation and checks

- Dart: `pure_position.dart`, `pure_tree_builder.dart`, `eca_calculator.dart`,
  `repertoire_selector.dart` under `lib/services/generation/`.
- C: `tree_builder/src/pure_search.c`; chesslib adapter in `san_convert.c`.
- Both use the v4 tree wire format with `history_aware`, terminal values,
  lower/upper bounds, and `algorithm_version: 3` in configuration.
- C JSON uses 17 significant digits so saved probabilities survive round trips.
- Shared fixture: 30 independently solved trees, both colors, chance nodes,
  constrained max nodes, exact terminals, and deterministic policy checks.
- Dart tests cover legal action enumeration, master/Maia support, tiny replies,
  cancellation/budget behavior, resume restrictions, promotion and repetition.
- C tests exercise the same oracle, legal-move fixtures, and the real builder
  through a deterministic UCI process. Run `make test-pure` in `tree_builder/`.

Correctness-preserving speedups can follow: reusable fixed-depth evaluations,
parallel evaluation, and rigorous bounded chance-node pruning. Rolling is
explicitly approximate and tested against this reference. Study selection and
exercise boundaries are a separate, reversible output layer.

## Bounded local database exploration

The Builder Generate pane explicitly sets `bounded_database: true`; normal Pure
builds keep their exhaustive contract. Engine-move count and Maia coverage are
adjustable in the pane, starting at four and 60%. At every position it explores the union of the top four Stockfish MultiPV
candidates and the most likely Maia moves until cumulative probability reaches
at least 60% (the move crossing the threshold is included). Strong but rare
opponent replies therefore remain in the database. Child evaluations use the
same configured engine depth. It does not impose a separate reply-count
cap. These are local reply probabilities, not whole-repertoire coverage.

This mode is approximate. Omitted Maia mass stays unnormalized: backup uses the
node engine value (or neutral value when unavailable) for its estimate and keeps
that missing mass in the uncertainty interval. The configured engine-loss guard
still applies to the final choice among evaluated own moves. Serialized configs
record the mode and thresholds; resume cannot silently switch their semantics.
The shared normal Pure and Fast options continue to use all positive Maia support.

Generation indexes newly attached nodes incrementally and looks up only the
board’s legal continuations on UI updates, allowing engine scores to appear
during expansion without repeatedly traversing the entire saved database.
Bounded probes retain their own root histories and policy distributions; the
latest position analysis overlays the lookup without grafting into Pure trees. Expected
scores appear when backup has computed them. The per-move play-circle is a
separate direct Stockfish PV request. Only the searched position receives that
engine score; its continuation is saved as independent UCI PV metadata (never inserted into
Maia policy children), and no expected score
is fabricated for a single engine line.

## V2 interactive Expectimax

The Builder's interactive Expectimax uses a bounded candidate policy rather than
an exhaustive Pure tree. From the root down, Stockfish at the panel's Engine
depth (default 14) supplies a
MultiPV shortlist of our moves: Root moves (default four) for our first move,
at the root or under each first reply, and Candidates (default four) after it.
Only those child positions get separate fixed-depth evaluations and recursive
expansion. A failed or incomplete shortlist stops with a visible error.
Callers without a ranking source score all candidates before retaining the best
N. Other callers retain their existing exhaustive defaults. The panel exposes
Maia rating, root moves, candidate count, depth in half-moves (blank for no limit),
engine depth and reply coverage directly above the results. Coverage is expressed as one in N
games, default 100; zero expands every reply. Settings apply to the next search
and are disabled during a run.

A practical search is run twice from the same board at once, on the one
engine (`FillGaps._buildMirror`): for the side at the bottom of the board, and
for the other side with the roles swapped, so the same position is our choice
in one tree and Maia's reply in the other. Each tree has its own 25,000-node
budget and is saved as its own run. The second exists for its values: the
table sets a move's expected score when White is the prepared side beside its
score when Black is, and beside the engine's. The gap between the engine and
the other side's column is how far a human on the move is expected to drift
from best play. The board's tree alone drives status, Positions and drafted
lines; the second stops with it unless the first ran its whole depth.

**Where the replies come from** (2026-10-01) is the bar's `Replies from`
choice: Maia (the default), Lichess masters, Lichess players at the speeds and
ratings the Explorer tab is set to, or the TWIC games on this machine
(`DatabaseOpponent` in `workspace/search_opponents.dart`). A database answers a
position with each legal reply weighted by its games (`playedPolicy`); a move
not legal there takes no weight and the two spellings of castling are one move.
With `Fall back to Maia under N games` ticked (the default, N = 10), a position
where the database has fewer than N games is answered by Maia instead. One
position has one source: the two are never blended, and whichever answers is
turned into shares of one over the legal moves (`Policy.sharesOver`) before the
cut below renormalizes what is kept, so every opponent position's replies sum
to one whatever scale its source counted in. Unticked, the database answers
wherever it has a game and the run stops where it has none. A database that
cannot be asked (no login, no connection, a rate limit, no TWIC import) stops
the run with its own sentence on the status line and keeps the tree; it never
turns into a Maia search. A saved tree records the choice
(`v2_reply_source`, such as `masters+maia<10` or
`lichess:Blitz,Rapid:2200,2500`; absent means Maia), and Resume only continues
a tree whose source, narrowing and fallback match.

Opponent nodes keep Maia's likeliest replies until they cover 90% of its
distribution, at most five, and renormalize the kept shares to sum to one
(`fillReplyMass`, `fillMaxReplies`). Maia's softmax gives every legal move some
weight, so without the cut each opponent position cost 30–40 engine
evaluations, most of them for replies under 2%. Kept paths below the configured
cumulative reach threshold (default 1%) stop at their engine estimate instead of
expanding further. The 25,000
new-node budget still bounds a batch. This is approximate candidate selection and
selective depth; an omitted engine candidate might have a better practical score.
Saved v4 configuration records `v2_max_our_moves`, `v2_root_moves`,
`v2_reply_floor`, `v2_reply_mass` and `v2_max_replies`; resumed interactive runs
require matching settings, except that a tree saved before the reply cut is cut
on load (`cutReplies`) rather than refused. Existing exhaustive trees
(including MCP-built chapter searches) can seed an interactive run; their completed
branches are retained, cut to the likeliest replies, while new expansions use the shortlist. Narrowed
trees carry algorithm version 4 so older exhaustive-only app/C/MCP readers refuse
to resume them under the wrong branching assumptions. Exhaustive exports stay at
algorithm version 3.

An active search follows board moves, move-list navigation and back/forward.
Navigation interrupts the old engine, saves its committed expansions, and starts
from the latest board only after that save finishes. A manual stop or a change
of document/side cancels the pending restart. Up to 16 previous roots are retained
in memory, so backing up displays their results immediately and a new search
reuses compatible values. Chapter searches also keep their existing saved trees
on disk. A stopped search stays stopped while browsing. The one Expectimax
button reads Resume expectimax when a compatible search covers the board, and
continues from the current board, not the old root, with its retained values.
Otherwise it loads a saved tree starting at the board (after restarting the
app), and when none fits it starts afresh there. Rating, evaluation source,
engine depth, candidate count and reply coverage must match to reuse an
interactive tree. The status line says only how far it got: Stopped at depth N
· X positions. Interactive trees saved before
the root was shortlisted (no `v2_root_moves`) are refused; start a new search.
Raising Root moves, or starting from a deeper node of an earlier search, evaluates
only the root moves that are missing and keeps the work below the others. Engine evaluations continue to use the shared
persistent cache independently of these in-memory search roots.

## Bughouse expectimax

Bughouse Lab's Expectimax tab and the website's `/bughouse` and `/bughousedb`
views share `bughouse_expectimax.db`. This is a single-board approximation:
ordinary moves and drops alternate on the selected board; captures feed the
partner's pocket, but no partner moves, clocks or sitting are expanded.

`chess/bughouse/expectimax.dart` computes both prepared colours in one tree.
All stored numbers are Q from White's side on the selected board. At a White
turn, White expectimax takes the maximum and Black expectimax averages the
children; at a Black turn, Black takes the minimum and White averages. Thus
White/Black columns are different decision models, not complements. The normal
repertoire builder already shows both columns in Practical mode; its deliberate
Mainline mode remains a single-side book.

At each node, retain Hivemind's best legal move plus the four highest CrazyAra
probabilities **strictly above 1%**, deduplicated. Only Hivemind's best move may
survive below that floor. Chance nodes use the original probabilities; omitted
mass retains the current searched evaluation. Coverage is stored and shown, so
this approximation never silently pretends the selected replies exhaust the
human distribution. Root rankings use the mover's prepared-colour value. This
is a candidate search, not a proof that every excluded move is worse.

CrazyAra 1.0.5 / OS-96 v1.0 supplies the legal root Policy column, with search
noise disabled, temperature 1, then legal normalization and FICS-fitted
postprocessing temperature 1.5. Diagnostic probabilities rounded to zero get a
1e-8 floor before this adjustment. This self-play model is an approximate human
policy: the held-out FICS experiment predicted 47.9% of moves; calibration does
not make its probabilities exact for every position or rating.

Hivemind searches each evaluated position (desktop default 1,500 nodes; overnight
builder default 3,000), with TimeAdvantage false and RequireMoveOn set to the
selected board. Since the opposite team can have neither board on move, its
searched value is not always available. The evaluator measures the position's
offset from both teams' static `policy` values, then subtracts that offset from
the selected mover's searched Q. This is approximate static-seat calibration,
not a claim that MCTS and static offsets are identical. Actual nodes and depth
are saved. Checkmate on either board is terminal under this no-waiting model.
Values are averaged in Q, then displayed on the existing Hivemind scale; they
are not pawns or empirically calibrated winning percentages.

The storage owner checkpoints every engine evaluation, keyed by full dual
position, selected board, binary/network hashes and node budget. Complete root
trees are stored separately, versioned by policy/search method, plies and node
budget. A partial or interrupted root is never published as complete. Both the
interactive lab and `tools/build_bughouse_expectimax.dart` use this same search
and cache. The lab stops on position changes or leaving the mode; completed
snapshots survive app restarts.

### Install and build the book

The optional CrazyAra installer currently supports Linux x86-64. It verifies
pinned hashes and installs private OpenVINO/TBB libraries and the OS-96 network.
It does not modify system libraries. Other platforms can supply a compatible
OS-96 installation through `CRAZYARA_BIN`; those platforms are not validated by
this installer. Upstream sources: [CrazyAra](https://github.com/QueensGambit/CrazyAra)
and [oneTBB](https://github.com/uxlfoundation/oneTBB).

```sh
scripts/ci.sh with -- python3 tools/setup_crazyara.py --destination "$HOME/.local/share/chess-prep/crazyara"
python3 tools/bughouse_db/expectimax.py seed --positions 1000
python3 tools/bughouse_db/expectimax.py run --workers 2 --cores 4 --nodes 3000 --plies 2 --hours 10
python3 tools/bughouse_db/expectimax.py stats
```

`seed` walks popular FICS continuations, reconstructing both boards. Each worker
atomically claims a board/position job, writes complete trees, and records
failures. Restart recovers interrupted jobs. The build is an explicitly
requested product job; run it under CPU/memory limits rather than an unrestricted
shell. Desktop checks still use the normal bounded CI runner and disposable data.

The API's `BUGHOUSE_EXPECTIMAX_PATH` points to the same SQLite format. Its public
read endpoint is `/api/bughousedb/expectimax?fen=...`; missing positions are shown
as missing, never replaced by ordinary engine scores. Admin import uses
`POST /api/bughousedb/expectimax/import` with `X-API-Key`, validates legal child
positions and bounded finite values, and accepts only the current model version.
The old clock-based evaluation book remains independent.

For a frozen overnight worker, build with `dart build cli --target tools/build_bughouse_expectimax.dart --output build/expectimax-cli` (through
`scripts/ci.sh with --`). Keep the entire generated `bundle/`, including its
native libraries, and pass `run --worker-bin /path/bundle/bin/build_bughouse_expectimax`.
The coordinator assigns disjoint CPU affinities to workers. A service can cap
combined CPU and memory, and `--hours` stops cleanly after its allotted run.
`--publish-to SSH_HOST --publish-path /absolute/bughouse_expectimax.db` merges
completed tables into the website database every five minutes; local engine
checkpoints are never uploaded. Network failures log and retry without losing
local results. Re-running with a larger node/ply budget requeues older jobs.
