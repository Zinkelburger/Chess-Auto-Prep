# Repertoire Planning — the sketch → generate → review workbench

Status: design + experimental evidence, August 2026. Nothing here is built yet.
The generation pipeline it drives already exists (`lib/services/generation/`,
`docs/ALGORITHM.md`); this document is about the *front door* and about two
algorithm changes the experiment showed are needed.

## The problem

Building a repertoire today means filling an ~880-line `TreeBuildConfig`
(`generation_config.dart`) and pressing Generate. The user's real input —
"here are the lines I want, find me consistent answers to everything else" —
has no place to go: there is one `startFen`, no seed lines, no way to say
"answer 2.Nf3 the way I answer 2.c4", and coherence is a post-hoc analysis
(`coherence_service.dart`), not a build input.

## Design principle

**Every decision the user makes is a chess move; every parameter is derived
from moves.** No wizard of forms — a workbench where the user *sketches* a
skeleton by playing it, the generator *fills* the gaps, and the user *reviews*
where the generator chose for them. One layout, three lenses.

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ Benko Gambit (Black)          [ Sketch ] [ Generate ] [ Review ]        ⚙ Advanced│
├──────────────────────┬───────────────────────────────┬───────────────────────────┤
│      BOARD           │  MOVES HERE (candidate table) │  TREE (skeleton + fill)   │
│                      │  Move  Masters Lichess Maia   │  ▾ 1.d4 Nf6               │
│  1.d4 Nf6 2.c4 c5    │        %  W/D/L   %      %  Eval│    ▾ 2.c4 c5              │
│  3.d5 b5             │  3.d5   62%  …    58%   61% +0.3│      ▾ 3.d5 b5  ●pinned   │
│                      │  3.Nf3  20%  …    24%   22% +0.2│      ▸ 3.Nf3 cxd4 ●pinned  │
│  [ ◀ ] [ ▶ ] [ ⤴ ]   │  3.dxc5  6%  …     5%    7% -0.1│    ▾ 2.Nf3 c5   ◐ auto     │
│                      │  ...                            │      ▸ 3.d5 b5  ✓ found   │
│                      │  Coverage of what you've        │    ▸ 2.Bf4 c5  ●pinned    │
│                      │  handled: 82% ▓▓▓▓▓▓▓▓░░       │    ▸ 2.e3   ○ uncovered   │
├──────────────────────┴───────────────────────────────┴───────────────────────────┤
│ Stockfish d24: +0.31   3.d5 b5 4.cxb5 a6 5.bxa6 e6 …      │ Expectimax (Black): +0.18│
└──────────────────────────────────────────────────────────────────────────────────┘
```

Board (left, the thing you touch), candidate table (middle, evidence for *this*
position), tree (right, the whole plan). Bottom strip: engine PV and expectimax
value, always on, never modal.

### Sketch lens

- **Our move played on the board ⇒ pinned (●).** No "add" button; undo unpins.
  Pasting a PGN into the tree pane lands as pinned nodes.
- **Their move to play ⇒ the candidate table is the question.** Rows ranked
  by combined probability (Maia × masters × lichess); ✓ answered, ○ uncovered
  above the coverage floor. Click a row to go there and answer it — or leave
  it and the generator will (◐ auto).
- **Coverage is the progress bar**: "you've handled 71% of what White plays
  here." That replaces `coverMinProb` in the user's head.
- **Eval warning inline, at pin time**: amber row, "−1.9 vs best −0.4. Keep? /
  Show me better". Not a modal.
- **Avoid everywhere** on right-click — a position feature ("pawn on d5",
  "queens traded early"), scored on the likely subtree, not a move name (see
  conclusion 6 below). Sources (Masters PGN file, Lichess, Maia Elo) are chips in the
  header; drop a `.pgn`/`.zip` on the Masters chip.

### Generate lens

Same layout. Tree nodes fill ○/◐ → ✓ as the frontier expands; clicking a node
mid-build shows what's known so far. Pause is resumable (`existingTree`).

### Review lens

Same layout plus a filter on the tree: *chosen for me* (◐, sorted by
probability — the review queue), *cost me eval* (pins that lost > tolerance),
*below cutoff* (greyed, with an illustrative single PV extended a few plies,
tagged so the trainer weights it lightly). Accepting is a click; disagreeing is
playing a different move ⇒ pin ⇒ **Rebuild from here** (subtree, resumable).
Chapters are coloured brackets on the tree; the model-games chapter is last.

### Hidden on purpose

The full config lives behind `⚙ Advanced` (the existing form, as a drawer; the
workbench writes the same `TreeBuildConfig`). Three plain-language sliders on
the coverage bar's popover: how rare a line still deserves a chapter (coverage
floor), how much eval you'll give up for a line you like (tolerance), how many
lines total.

## What the experiment showed

`tools/experiments/skeleton_consistency/` scores candidate Black moves at
seven White deviations, given only the Benko skeleton (and, in a second pass,
also `2.c4 c5 3.Nf3 cxd4 4.Nxd4 e5`). Data: Stockfish 18, Maia-3 at 1800,
ChessDB evals. Sources of candidates: engine MultiPV-8, ChessDB top-8, Maia
top-6, and "transfer" moves (see below). Tolerance 40 cp vs ChessDB best.

| Position (expected) | engine | expectimax | transfer ≤5 | exact reach | pawn Jaccard |
|---|---|---|---|---|---|
| 2.Nf3 (…c5) | d5 ✗ | d5 ✗ | **c5** | c5 only with L1 | e6 ✗ |
| 2.Nf3 c5 3.d5 (…b5) | b5 | e6 ✗ | **b5** | b5 | e6 ✗ |
| 2.Nf3 c5 3.c4 (…cxd4) | cxd4 | d5 ✗ | cxd4 (with L1) | cxd4 (with L1) | — |
| 2.Bf4 (…c5) | c5 | Nh5 ✗ | **c5** | c5 | e6 ✗ |
| 2.Bf4 c5 3.e3 (…Qb6) | d5 ✗ | **Qb6** | d5 ✗ | d5 ✗ | e6 ✗ |
| 2.e3 (…c5) | e6 ✗ | d5 ✗ | **c5** | e6 ✗ | e6 ✗ |
| 4.Qxd4 (…Nc6) | Nc6 | d5 (!) | — | Nc6 | Nc6 |

Tally, both skeletons: engine 4/7 · expectimax 1/7 · transfer 6/7 · exact
reach 4/7 · pawn-structure 0–3/7.

Seven conclusions:

1. **Engine MultiPV alone can't even *see* the consistent move.** Stockfish
   d20 MultiPV-8 leaves …c5 out of its list both after 2.Nf3 and after 2.Bf4
   (where ChessDB has …c5 as *best*). Today's selector draws our candidates
   only from MultiPV (`ourMultipv`, default 3), so no scoring change can fix
   this — **candidate generation must union in Maia's top moves, ChessDB's
   top moves, and skeleton-transfer moves.**
2. **"Transfer" is the metric that works, and it is trivially explainable.**
   Transfer = the move the skeleton plays at its *nearest* our-turn node,
   measured as number of differing squares, capped at 5, and only if it is
   within tolerance. After 2.Nf3 the nearest skeleton node is "after 2.c4"
   (4 squares differ) and it played …c5; likewise after 2.Bf4, 2.e3, and after
   2.Nf3 c5 3.d5 (→ …b5). The UI can say "like your line vs 2.c4". Without the
   cap it misfires (picked …a6 at 3.c4, distance 7).
3. **Exact-transposition reach is the right *second* signal** — it fires when
   the skeleton is rich (…c5 vs 2.Nf3 becomes ✓ once `3.c4 cxd4 4.Nxd4` is in
   the skeleton) and never fires wrongly. Cheap: `fen_map.dart` already tracks
   transposition leaves.
4. **Expectimax finds the "challenging" moves the skeleton can't.** …Qb6 vs
   the London: static evals are d5 = 0, Qb6 = −1, e6 = −1 — indistinguishable —
   but Maia-weighted expectimax gives Qb6 **+22 cp** because 1800-level White
   goes wrong so often (4.Nc3?, 4.b3?, 4.Qc1). Same after 4.Qxd4: …d5!? is
   sound (−1) and 5.Nc3?? (35 % of replies, +1.45) / 5.Bg5? (11 %, +1.08) make
   it +62 cp in expectation. That's a genuine *trappy* alternative to the
   *common* …Nc6, and the reason to show both.
5. **"Coherence" — SAN-token itemsets or pawn-structure similarity to the
   goal — is dead.** Both rank …e6 "consistent" everywhere because the Benko
   goal position *contains* e6; a move name or a resemblance to the final
   structure says nothing about the position at hand. Dropped. (Transfer is a
   different thing: nearness to a *position where the user already decided*,
   not similarity of move names.)
6. **Explicit structure preferences work as a veto, not as a vote.** Scoring
   candidates by user-declared features over Maia-2300-likely positions four
   plies down (pawn on c5 +1, d6 +½, pawn on d5 −1, queens traded −½):

   | position | top by structure | the …d5 approach |
   |---|---|---|
   | 2.Nf3 | e6 1.00, c5 0.91, g6 0.84 | d5 **0.27** |
   | 2.Bf4 | e6 1.00, d6 0.95, c5 0.84 | d5 **0.00** |
   | 2.e3 | e6 1.00, c5 0.78 | d5 **0.02** |
   | 2.Bf4 c5 3.e3 | Qb6 1.00, e6 1.00 | d5 **−0.24** |
   | 4.Qxd4 | Nc6/e6/g6 0.00 | d5 **−0.14** (5.cxd5 Qxd5, queens off) |

   Every QGD-ish …d5 approach is killed decisively, but …c5-now and
   …e6-then-…c5 are indistinguishable because both reach c5 structures.
   So: structure preferences filter; transfer and expectimax select.
7. **Opponent Elo changes the "trappy" numbers a lot; report it.** At Maia
   1800 vs 2300: 4.Qxd4 …d5 expected gain +62 → +19 (5.cxd5 goes from 44 % to
   83 %); …Qb6 vs the London +22 → +4 (still top; 4.Nc3 61 % at 2300).

### Selection order this supports

1. Soundness gate: eval loss ≤ tolerance.
2. Structure vetoes: 2–4 user-declared "avoid" features scored on the expected
   subtree (pawn on d5, early queen trade, symmetrical pawns).
3. Transfer: among survivors, the move played at the nearest skeleton position
   (≤ 5 differing squares) — surfaced as "like your line vs 2.c4", pinned by
   the user rather than silently selected.
4. Expectimax at the Elo the user faces: picks the challenging move when 2–3
   are silent (…Qb6), and breaks ties.
5. Candidate union (engine MultiPV ∪ Maia ∪ ChessDB ∪ transfer) underneath all
   of it, or step 3 never sees …c5.

## Algorithm changes this implies

In priority order; each is small and independently testable against the
skeleton as a golden test ("does the build find …c5 vs 2.Nf3 unaided?").

1. `TreeBuildConfig.skeletonPgn` (or `List<String>` SAN lines). Parse to
   pinned our-moves (hard: always selected, eval-checked, warned if outside
   `maxEvalLossCp`) and multiple build roots.
2. Candidate union at our-turn nodes: engine MultiPV ∪ Maia top-k ∪ ChessDB
   top-k ∪ transfer moves. Everything still passes the eval-loss filter.
3. Transfer prior in `repertoire_selector`: among candidates within tolerance,
   a move that transfers from a skeleton node at distance ≤ 5 wins; ties broken
   by expectimax. Then exact reach; then expectimax. Record the reason on the
   node (`consistentWith: "2.c4 c5"`) so the UI can show it.
4. Report both rankings per node — *common* (reach probability) and *trappy*
   (expectimax − static eval) — and let the chapter planner keep a trappy
   alternative when its expected gain is large (…d5 vs 4.Qxd4).
5. Replace `setupMoves` (move-name preferences) with position features scored
   on the expected subtree — "avoid pawn on d5", "avoid early queen trade" —
   for the "avoid everywhere" gesture. Move-name preferences are the coherence
   idea in disguise and fail the same way.

## Eval sources when the user has no database

Today `enableChessDbApi` defaults to `false`, uses only `action=queryscore`,
and stops at a self-imposed 5000/day (`chessDbApiDailyQuota`). The ChessDB
cloud API (https://www.chessdb.cn/cloudbookc_api_en.html) has no published
daily quota — it limits *request rate* — so the plan is:

1. **Default on** when neither cdbdirect nor a local ChessDB sqlite is
   configured/resolvable. Header chip: "ChessDB (cloud)".
2. **Run until the server says stop**: on HTTP 429 / "rate limit" body →
   exponential backoff (1 s → 60 s); after N consecutive limits mark the
   provider cooled-down for the rest of the day, chain falls through to the
   engine, chip reads "ChessDB (rate-limited — engine only)". The daily-quota
   knob stays only as an optional user ceiling.
3. **`queryall` at our-turn nodes** instead of `queryscore`: one request →
   every known move with score/rank, i.e. the candidate-union source and the
   soundness gate in one call. `queryscore` remains for leaf evals.
4. **`queue`** unknown positions in the background so tomorrow's run has them.
5. Hygiene: HTTPS, identifying `User-Agent`, concurrency ≤ 2, and cache every
   hit in `eval_cache.db` so a position is never asked twice.
