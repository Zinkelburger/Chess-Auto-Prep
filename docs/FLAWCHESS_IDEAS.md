# FlawChess-inspired features — design and implementation plan

Ideas adopted from [FlawChess](https://github.com/flawchess/flawchess) (AGPL-3.0,
same license as this project). Their engine ranks moves by *expected practical
score* (Stockfish quality × Maia human probability, expectimax inside an MCTS
budget allocator). Four ideas port to us; the rest of their design either
duplicates what we have (win-prob sigmoid, anytime snapshots) or is worse for
repertoire building (truncate-and-renormalize vs our raw-probability tail term,
no coverage guarantee, 6–10 ply depth cap).

Implemented July 2026. Reference formulas below cite their source files.

## 1. Flaw attribution tags on mined tactics

Port of their tag taxonomy (`docs/flaw-tag-definitions.md`,
`app/services/flaws_service.py`). Every mined tactic gets orthogonal tags, at
most one per family:

- **Impact** — outcome-independent expected-score ladder, most-severe-wins:
  `reversed` (ES before ≥ 0.6762 ≈ +2.0 and after ≤ 0.3238 ≈ −2.0),
  `squandered` (before ≥ 0.7511 ≈ +3.0 and after ≤ 0.5910 ≈ +1.0, not
  reversed). ES = (winningChance + 1) / 2 on our existing [-1, 1] scale, so the
  constants match their sigmoid exactly (same Lichess k = 0.00368208).
- **Opportunity** — `miss`: the opponent's move immediately before the user's
  error was itself a mistake/blunder (user's winning chance *rose* ≥ 0.2 across
  it). `lucky`: a user *blunder* whose immediate opponent reply was a
  mistake/blunder (wc rose ≥ 0.2 across the reply); end-of-game blunders count
  as lucky only when the user did not lose. Both computed by diffing the
  win-chances the miner already evaluates on adjacent user turns — zero extra
  engine calls. (Their 2026-06-07 bug: an inverted `lucky` tagged 42% of
  blunders; ours follows the fixed semantics.)
- **Tempo** — `low-clock` (clock after move < 5% of base time, fallback 30s),
  `hasty` (move time < 1% of base, fallback 5s, priority below low-clock),
  `unrushed` (had time, took time, still erred). Move time = same-side clock
  two plies back − clock after + increment; negative → treat as unavailable.
  **No tag at all when clock data is missing** — absence of `unrushed` and
  "couldn't measure" are distinct; never normalize measured segments to 100%.
- **Phase** — `opening` / `middlegame` / `endgame` from a per-position
  material classifier (simplified Lichess divider: endgame when majors+minors
  ≤ 6; middlegame when ≤ 10 or a back rank has < 4 pieces; else opening).

Severity itself is unchanged (existing ??/?/?! win-chance drops 0.3/0.2/0.1 —
already equivalent to their 15/10/5 ES points).

Implementation: pure tag logic in `lib/services/tactics/flaw_tagger.dart` +
`lib/utils/game_phase.dart` + `lib/utils/clock_utils.dart` ([%clk] parser,
TimeControl base+increment parser). Miner (`tactics_import_analysis.dart`)
collects per-ply wc + clock series and assigns `TacticsPosition.flawTags`
after the walk (lookahead needed for `lucky`). `TacticsPosition` grows a
`flawTags` list (CSV column 22; old 21-column rows parse as empty). Lichess
downloads now request `clocks=true` (chess.com PGNs already carry [%clk]);
already-downloaded Lichess games simply get no tempo tags until re-imported.
Browse UI: tag chips on rows + a tag filter following the mistake-type chip
pattern.

## 2. Memorability bias in repertoire selection

FlawChess's findability insight inverted for prep: within a small eval
tolerance, prefer the our-move the user would *naturally play anyway* (highest
own-side Maia probability) — natural moves are cheaper to memorize and survive
forgetting. Demote-only safety comes from the eval gate: a natural move can
only win the tie-break if it is within `memorabilityToleranceCp` of the best
sibling (and never past `maxEvalLossCp`).

Implementation: `_applyMemorabilityBias` in `repertoire_selector.dart`,
mirroring `_applySetupBias` (post-hoc winner override: eval-tolerance gate,
then argmax `maiaFrequency`, which the build already populates on every
our-move child). Applied before setup bias so an explicit preferred system
still wins. Config `memorabilityToleranceCp` (default 0 = off). Note the
deliberate tension with `noveltyWeight` (novelty prefers rare moves): they are
opposite preferences; enabling both lets novelty shape the mode winner and
memorability only override within tolerance.

## 3. Trap scores weighted by punishment findability

`analyzeTrapScore` previously scored a trap as
`clamp(evalDiff/200, 0, 1) × P(opponent plays the popular blunder)` — ignoring
whether the *punishing reply* is a move a human would find. A trap whose
refutation is inhuman is not a practical trap. New factor, from FlawChess's
`findability.ts`:

```
factor = min(1, pRefutation / pRef(elo))
```

where `pRefutation` is the refutation our-move child's `maiaFrequency` and
`pRef` interpolates their Elo anchors (600→0.12, 1000→0.08, 1400→0.05,
1800→0.03, 2200→0.015, 2600→0.005) at `config.maiaElo`. Demote-only: the
factor caps at 1, so findable refutations change nothing. When Maia data is
absent (`maiaFrequency < 0`) the factor is 1 (no distortion). Anchors +
interpolation live in `lib/utils/findability.dart`.

Refutation = best reply for us under the popular blunder (the repertoire move
when already selected, else highest `evalForUs`), consistent with
`TrapExtractor._findRefutation`. Affects `node.trapScore` (display) and trap
extraction gating; `cplValue` (trappy selection accumulator) is untouched.

## 4. Opponent policy temperature

Their "Play style" slider, applied to *our opponent model*: exponent
`p → p^(1/T)` on the Maia policy before truncation, then renormalized over the
full policy (legal-move distributions are inherently normalized; the
no-renormalization convention protects only the *truncated subset* feeding the
expectimax tail term, which is downstream and unchanged). T > 1 flattens
(sloppier, more diverse pool), T < 1 sharpens (book-heavy pool), T = 1 no-op.

Implementation: `applyPolicyTemperature` in `opponent_prior.dart`, applied at
both Maia entry points in `node_expander.dart` (`_addOpponentChildrenFromMaia`
and `maiaPolicyForSmoothing`, i.e. before `maiaMinProb` filtering and
`oppMassTarget` truncation). Config `oppPolicyTemperature` (double, default
1.0), knob in the Opponent model section of the advanced generation form.

## Deliberately not adopted

- **Truncate-to-90%-mass + renormalize** (their candidate selection): our raw
  probabilities + expectimax tail term are strictly more honest about
  uncovered mass.
- **Self-fallibility averaging at our own deeper nodes**: correct for their
  use case (nothing memorized), wrong inside a repertoire you train — max at
  our nodes stands. Its spirit lands via #2 and #3 instead.
- **PUCT/uncertainty-driven budget allocation**: our 2026-07-16 audit showed
  ordering isn't where generation speed lives (pruning is); revisit only if a
  profile says otherwise.
- **Findability re-ranking of the recommended move itself**: repertoire moves
  are memorized, so first-move findability doesn't gate us the way it gates
  their per-position advice.
