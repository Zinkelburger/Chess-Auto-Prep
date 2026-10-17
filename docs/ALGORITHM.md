# Pure expectimax contract

The app's search (`lib/chess/generation/search.dart`), the standalone C builder
(`tree_builder/`) and the chess-prep MCP, which launches that builder, share
one finite-horizon recurrence and the v4 tree format. This document defines
that contract, called **Pure**. The C builder and MCP can also run an
approximate receding-horizon variant, [Fast](#fast-search-c-builder-and-mcp-only);
the app has no Fast and refuses to open Fast trees. The app's Search tab runs
Pure with a narrower candidate policy, described under
[Interactive Expectimax](#interactive-expectimax-search-tab). The ChessDB
mainline book (`lib/chess/generation/mainline_book.dart`) and the C builder's
database build modes are separate build sources.

## What is optimized

Choose a fixed repertoire side, a horizon H in half-moves from the supplied
root, an engine depth D, a maximum engine loss L in centipawns, and an opponent
policy. The default horizon is 4 plies (C `-d`, Dart `SearchConfig`). A larger
horizon is exponentially more expensive, even with just a few plies of
preparation.

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
above 9000 saturate to 0 or 1 (`expectedScore` in
`lib/chess/generation/eval.dart`). This is a bounded **expected-score
estimate**, not a calibrated human win probability. The engine-loss constraint
and leaf utility depend on Stockfish's estimates. Search correctness does not
prove that those estimates, the opponent model, or the resulting move are
objectively correct chess. Stockfish itself remains a selective engine search.

The selected move uses exactly the same scorer as the maximizing backup.
Ties use engine evaluation, then UCI, then SAN (`compareCandidates`). There are
no novelty bonuses, confidence blends, setup preferences, memorability bonuses,
skeleton overrides, reply-count preferences, or separate selection objectives.

## Opponent model

**The C builder and MCP use Stockfish + Maia only.** Stockfish supplies
position estimates and the own-move loss constraint. Maia, at the requested
opponent rating, supplies every opponent position's move probabilities. The
legal probabilities are normalized to sum to one; every positive-probability
legal reply remains in the search. There are no master counts, database
fallbacks, blends, probability-temperature changes, or hidden reply caps.
For Stockfish expectimax, `main.c` forces `maia_only` on and master games off,
whatever `--masters`, `--lichess` or a `--resume`d setting says; those flags
apply only to the database build modes. The app's Search tab uses Maia by
default and can instead take replies from a game database
([Where the replies come from](#where-the-replies-come-from)).

The C builder can apply the app's reply cut when asked: `--reply-mass <share>`
keeps the likeliest replies until they cover that share and `--max-replies <N>`
caps their number; the kept shares are renormalized to sum to one
(`pure_cut_replies`, mirroring the app's `likeliestReplies`). The chess-prep
MCP `expectimax_run` passes the app's values (90%, at most five) unless it is
continuing a tree that records another cut. A saved tree records the cut as
`v2_reply_mass` / `v2_max_replies`; the builder continues a tree with its own
cut when no flag is given and refuses a different one, so a tree built before
the cut keeps every reply.

A missing or invalid Maia policy is an error. It never triggers a switch to a
game database: C refuses to start without a Maia model, and the app's search
stops with `PolicyMissing`, keeping the tree it had.

Saved trees record `opponent_book_source: "none"`, `use_master_games: false`
and `maia_only` (true unless a database answered the replies), plus
`maia_policy_version: 1` (see [Maia repeatability](#maia-repeatability)). The
C builder refuses to continue a tree with any other policy version, and trees
built with master probabilities cannot resume: start a fresh build. Changes to
the Maia or Stockfish model files can still affect newly evaluated positions.

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
en-passant availability. History before the supplied root is unknown
(`lib/chess/generation/terminal.dart`).

This is an explicit draw-claim convention, not full modeling of optional or
prospective draw claims. General dead positions beyond recognized insufficient
material, arbitrary game history before a FEN, and tablebase proofs are outside
this model. “100% correct chess” would require those inputs and additional rules.

## Completion, budgets, and resume

Both builders expand breadth-first: the shallowest unexpanded node goes first,
so an unfinished search has seen the whole choice shallowly rather than one
line deeply. An expansion is committed atomically: first construct its complete
action set and evaluations, then attach it to the tree. Cancellation, time
limits, or a node budget never leave a partial probability distribution or
partial legal candidate enumeration. The budget is checked against every legal
move before the first evaluation, so a node budget may leave some allowance
unused when the next complete expansion cannot fit. An in-flight engine
evaluation may finish after a requested time limit.

Unresolved frontier values are provisional. Their bounds are [0,1]; exact
terminals and evaluated horizon leaves have equal bounds. Bounds propagate by
max at our nodes and probability-weighted sum at opponent nodes. They bound
the defined finite model, not Stockfish error or real-world playing strength.
An incomplete result is labeled as such and does not claim its leader is solved.

The C builder resumes only with the same root, repertoire side, engine depth,
engine-loss limit, Maia rating, book source (`none`), search method and reply
cut. The horizon can increase, but cannot shrink. Already expanded
policies/evaluations are retained; new frontier queries use the currently
available engine and model. For a uniform fresh comparison after changing any
of these sources, start a new run. Heuristic trees written by earlier builder
versions (no `history_aware` root) cannot be resumed and must be rebuilt; the
C builder still reads them for review. The app's resume rules are under
[Interactive Expectimax](#interactive-expectimax-search-tab). The app's reader
(`tree_wire_v4_reader.dart`) refuses heuristic trees, Fast trees and trees
marked `bounded_database: true`.

## Export and verification

The C builder's export follows the maximizing policy and every
positive-probability opponent reply. Pure paths are not folded by FEN or
discarded by diversity, cumulative probability, or absolute evaluation windows.
Optional output products such as trap-only collections remain output choices;
they are not the tree's optimized policy.

There is no separate deep-verification pass for Pure. To strengthen evaluation,
rebuild at the desired engine depth, so all legal moves are admitted or rejected
at that depth. The C builder's verifier (`--verify-depth`) works only on
heuristic trees: it re-evaluates the entire saved tree, commits only a completed
pass, and always recomputes values and selection. It can only check saved
candidates; it cannot recover moves a heuristic build omitted.

## Fast search (C builder and MCP only)

Fast is an approximate receding-horizon variant of Pure, implemented only in
`rolling_build` (`tree_builder/src/pure_search.c`). The app has no Fast and
its reader refuses Fast trees. The opponent model, engine-loss
constraint, fixed engine depth, history, draw convention and leaf utility are
identical to Pure. At each of our decisions:

1. Search every admissible move and every positive-probability opponent reply
   through four more plies, or the requested final horizon if closer.
2. Complete that comparison before committing our next move. Keep its UCI,
   absolute comparison horizon, and comparison value in the saved tree.
3. Continue every modeled opponent reply after that move. At each resulting
   decision, repeat the four-ply comparison. Previously searched nodes are reused.

This chooses **one of our moves**, not a single predicted sequence of opponent
moves; every modeled opponent branch is still followed. It is limited lookahead
and can miss a refutation or benefit beyond its window. It is not a guaranteed
policy improvement over Pure or a proven chess-strength improvement. Four plies
is fixed; the preparation horizon still controls how far the resulting policy
continues.

A saved comparison value answers “which next move won this completed short
comparison?” The final expected-score value instead evaluates the **committed
policy** to the requested horizon; it does not maximize again over siblings
searched to different depths. The MCP result therefore puts the committed move
first and suppresses a margin over those siblings.

A budget stop cannot commit an unfinished comparison. Uncommitted own decisions
are unresolved, with bounds [0,1], and are not exported as guessed repertoire
moves. Completed local commitments can appear in incomplete preparation, which
is labeled incomplete. Equal final bounds describe the committed finite policy,
not the best possible full-horizon policy or true chess strength. Resume keeps
commitments whose four-ply windows were complete; increasing the horizon
reopens a decision whose comparison had stopped short of four plies. Pure and
Fast cannot be interchanged on an existing tree.

- CLI: `tree_builder --search fast ...` (`rolling` is an alias); omit it for
  Pure. Continuing a tree without `--search` keeps the tree's method.
- MCP: `expectimax_run` accepts `search: "fast"` or `"pure"` (`rolling` is an
  alias) and launches the builder with `--search rolling`. Its result reports
  `search_method`, `decision_lookahead` and a `score_kind` that names the
  committed Fast policy.
- Saved v4 trees keep `search_algorithm: "rolling"` and
  `algorithm_version: 3`; Fast nodes add `committed_move_uci`,
  `decision_horizon` and `decision_value`. PGN exports carry
  `[Search "Fast (4-ply, approximate)"]`.

**Measurements.** The independent oracle `test/fixtures/generate_rolling_oracles.py`
builds 12 complete binary chance/decision trees, eight plies deep, both
repertoire colors, with deliberate horizon failures; `make test-pure` checks the
C builder against every commitment and policy value. Across these synthetic
cases Fast visits 2,388 distinct nodes versus 6,132 for full search (61.1%
fewer); its mean loss against the full finite-tree optimum is 0.0474
expected-score units, worst 0.1470. These are synthetic algorithm checks, not a
chess benchmark or a wall-clock claim.

## Implementation and checks

- Dart: `lib/chess/generation/` — `search.dart` (`buildSearchTree`),
  `search_node.dart` (backup, bounds, `compareCandidates`), `terminal.dart`,
  `eval.dart`, `sources.dart` (`likeliestReplies`), `tree_wire_v4.dart` and
  `tree_wire_v4_reader.dart`. The Search tab drives it from
  `lib/workspace/fill_gaps.dart`, `fill_states.dart` and
  `search_opponents.dart`; Maia inference is `lib/engines/maia/`.
- C: `tree_builder/src/pure_search.c` (Pure and Fast); chesslib adapter in
  `san_convert.c`; `tree.c` dispatches the default build mode to
  `pure_tree_build`.
- Both write the v4 tree format with `history_aware`, terminal values,
  lower/upper bounds, and `algorithm_version: 3` in configuration (4 for the
  app's shortlisted trees). C JSON uses 17 significant digits so saved
  probabilities survive round trips.
- Shared fixture: `test/fixtures/pure_expectimax_oracles.json`, 30
  independently solved trees (both colors, chance nodes, constrained max nodes,
  exact terminals), generated by `generate_pure_oracles.py`. Dart checks it in
  `test/chess/generation/pure_oracle_test.dart` and
  `pure_search_oracle_test.dart`; the rest of `test/chess/generation/` covers
  legal enumeration, terminals, the reply cut, shortlists, pins and reply
  floor, budgets, resume and the wire format.
- C: `make test-pure` in `tree_builder/` runs the Pure oracle, the Fast oracle,
  the real builder against a deterministic UCI process, and the parallel-pool
  checks.

**Parallel evaluation.** Engine work is the expensive part, and siblings do not
depend on each other. The app asks for all of one node's children at once
(`Future.wait` in `_leavesOf`) and reads the answers back in move order, so a
failure always reports the first failing move. The C builder evaluates all
legal candidates of a node together and batches up to 256 horizon leaves,
including leaves from different reply branches, through its engine pool. Maia
inference and tree bookkeeping stay serial in both. More workers do not remove
exponential branching. Real Stockfish hash histories can give slightly
different fixed-depth scores across schedules; the objective is unchanged.

### Maia repeatability

With the bundled Maia model and ONNX Runtime 1.15.1, the first inference for
`8/8/8/8/P7/3k4/8/4K3 b - - 0 2` gave `d3c4` probability 0.92199 and every
later one 0.92059, with no concurrent Maia call. Turning ONNX Runtime's memory
patterns off (they reuse the first run's allocation pattern) made first and
repeated results agree; the internal cause was not established. Both
implementations still disable them: Dart calls `DisableMemPattern` through the
ORT C API in `createMaiaSession` (`lib/engines/maia/maia_model.dart`), because
the Dart wrapper lacks the option, and C does the same in `maia.c`. Both also
request one intra-op thread, since the runtime's pool otherwise sums partial
results in thread-finish order. Trees built this way record
`maia_policy_version: 1`; older trees need a fresh build rather than mixing
probabilities from the two inference configurations.

## Interactive Expectimax (Search tab)

The app's Expectimax uses a bounded candidate policy rather than an exhaustive
Pure tree, and no engine-loss window. From the root down, Stockfish at the
configured Engine depth (default 14) supplies a MultiPV shortlist of our moves
(`FixedDepthCandidates`): First move (default four) for our first move, at the
root or under each first reply, and Later moves (default four) after it. Only
those child positions get separate fixed-depth evaluations and recursive
expansion. A failed or incomplete shortlist stops with a visible error.
Callers without a ranking source score all candidates before retaining the best
N. The Search tab's Expectimax bar and gear, mirrored in Settings ▸ Expectimax,
set the Maia rating, First move, Later moves, Depth in half-moves (blank for no
limit), Engine depth, evaluation source and `Search replies met once in N`
games (default 100; zero searches every reply). Settings apply to the next
search and are shown but locked during a run.

A practical search is run twice from the same board at once, on the one
engine (`FillGaps._buildMirror`): for the side at the bottom of the board, and
for the other side with the roles swapped, so the same position is our choice
in one tree and Maia's reply in the other. Each tree has its own 25,000-node
budget (`fillNodeBudget`) and is saved as its own run. The second exists for its values: the
table sets a move's expected score when White is the prepared side beside its
score when Black is, and beside the engine's. The gap between the engine and
the other side's column is how far a human on the move is expected to drift
from best play. The board's tree alone drives status, Positions and drafted
lines; the second stops with it unless the first ran its whole depth.

### Where the replies come from

The bar's `Replies from` choice: Maia (the default), Lichess
masters, Lichess players at the speeds and
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

Each opponent position also keeps who answered it (`PolicyFound.from`,
`OpponentNode.repliesFrom`, written per node as `v2_replies_from`: `games` or
`maia`), so a resumed or reopened tree still knows. The Expectimax table shows
it on the Played share only: a database share is plain, a Maia stand-in reads
`~38%`, and the share's tooltip names the source (`From Lichess masters`, or
`Maia 2200; Lichess masters has under 10 games here`). A Maia-only search and a
tree saved before sources were kept show neither marker nor tooltip.

### Reply cut, reach floor and saved settings

Opponent nodes keep the likeliest replies until they cover 90% of the
distribution, at most five, and renormalize the kept shares to sum to one
(`fillReplyMass`, `fillMaxReplies`). Maia's softmax gives every legal move some
weight, so without the cut each opponent position cost 30–40 engine
evaluations, most of them for replies under 2%. Kept paths whose reach falls
below one in N games (default 1%, `SearchConfig.replyFloor`) stop at their
engine estimate instead of expanding further. The 25,000 new-node budget still
bounds a batch. This is approximate candidate selection and selective depth;
an omitted engine candidate might have a better practical score.

Saved v4 configuration records `v2_max_our_moves`, `v2_root_moves`,
`v2_reply_floor`, `v2_reply_mass` and `v2_max_replies`; a resumed run requires
matching settings, except that a tree saved before the reply cut is cut on load
(`cutReplies`) rather than refused. An exhaustive tree with no loss window can
seed an interactive run; its completed branches are retained, cut to the
likeliest replies, while new expansions use the shortlist. A tree saved with a
loss window, which includes every C and MCP build, is refused. Shortlisted
trees carry algorithm version 4, which the MCP's chapter reader
(`expectimax_chapters.py`) refuses; exhaustive trees stay at version 3.

### Following the board and resuming

An active search follows board moves, move-list navigation and back/forward.
Navigation interrupts the old engine, saves its committed expansions, and starts
from the latest board only after that save finishes. A manual stop or a change
of document or side cancels the pending restart. Up to 32 earlier trees (two
per practical search) are retained in memory, so backing up displays their results immediately
and a new search reuses compatible values. Searches also keep their saved trees
on disk. A stopped search stays stopped while browsing. The one search button
reads Resume when a compatible search covers the board, and continues from the
current board, not the old root, with its retained values. Otherwise it loads a
saved tree starting at the board (after restarting the app), and when none fits
it starts afresh there. Rating, evaluation source, reply source, engine depth,
Later moves and reply floor must match to reuse an interactive tree. The status
line says only how far it got: `Stopped at depth N · X positions`. Interactive
trees saved before the root was shortlisted (no `v2_root_moves`) are refused;
start a new search. Raising First move, or starting from a deeper node of an
earlier search, evaluates only the root moves that are missing and keeps the
work below the others. Engine evaluations also use the persistent
`eval_cache.db` (`lib/storage/eval_cache.dart`), independently of these
in-memory search roots.
