# Hivemind budget study — 2026-10-02

## Working recommendation

Use **800 MCTS nodes for a preliminary bulk evaluation**, then refine close or
unstable decisions at **3,000 nodes**, escalating difficult cases to 8,000.
Keep a separate **100,000-node winning-mate probe**. Do not replace searched
evaluations with the bare neural value, and do not treat a cheap score as a
precise ranking of close candidates.

This is a small, stratified pilot of the installed CPU engine. It establishes
a useful cost/consistency tradeoff, not a universal strength threshold or an
Elo rating. No production settings or databases were changed, and the bulk
builder and scheduled monitor remain stopped.

## Neural search: 24 FICS positions

Eight early positions without reserves, eight later positions with reserves,
and eight positions in check; one per game, both physical boards represented.
All positions have at least two legal moves on the selected board. Five cold
searches per position give **120 searches**, plus two static seat evaluations
per position. No time advantage; the selected board must move.

Each engine job had a two-core CPU quota on a shared Intel Core Ultra 7 165H,
using ONNX Runtime, batch 8, four search workers and five intra-op threads. Timings exclude engine
startup; static calibration costs another 0.21 seconds median per position.
The timing ratios are approximate and are not predictions for a GPU or other
CPU allocation. Search order was deterministically shuffled within each case.

The reference is 8,000 requested nodes, **not ground truth**. Q differences
below are on the bounded internal value scale after the same static seat-offset
correction used by the table builder. They are not centipawns, Elo, or calibrated
win-probability differences.

| Requested MCTS nodes | Median seconds | Mean absolute ΔQ | 90th-percentile ΔQ | Maximum ΔQ | Same selected-board move as 8,000 | Cases with ΔQ > 0.10 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Network only | 0.21 | 0.0991 | 0.1769 | 0.9819 | — | 6/24 |
| 100 | 2.20 | 0.0403 | 0.0837 | 0.1986 | 17/24 | 1/24 |
| 300 | 4.61 | 0.0421 | 0.1190 | 0.1405 | 19/24 | 3/24 |
| 800 | 11.25 | 0.0280 | 0.0714 | 0.1332 | 19/24 | 1/24 |
| 3,000 | 40.60 | 0.0146 | 0.0435 | 0.0854 | 22/24 | 0/24 |
| 8,000 reference | 107.49 | — | — | — | — | — |

Budget is not strictly monotonic in this sample: 300 nodes had more large
deviations than 100. A small sample, MCTS exploration and changing preferred
lines can all contribute. It would be incorrect to conclude that 100 is
generally stronger than 300. Batched searches usually overshot the request by
about 40–47 nodes, so a nominal 100-node search actually used about 140.

Mean absolute ΔQ by stratum:

| Budget | Early/no reserves | Reserves | In check |
| ---: | ---: | ---: | ---: |
| Network only | 0.0486 | 0.0774 | 0.1712 |
| 100 | 0.0275 | 0.0662 | 0.0273 |
| 300 | 0.0291 | 0.0664 | 0.0308 |
| 800 | 0.0186 | 0.0370 | 0.0284 |
| 3,000 | 0.0079 | 0.0248 | 0.0111 |

Notable cases:

- `check-04`: the network-only corrected value was −0.0181; all searched
  budgets reported a forced loss and value −1. There is only one reference
  mate in this FICS sample, so this is an example, not a mate-recall estimate.
- `reserves-08`: 100 nodes gave −0.9951, versus −0.7966 at 8,000. Its king move
  also changed. A near-terminal-looking value from a tiny search can mislead.
- `check-02`: 800 nodes selected the same move as 8,000, but the value was
  +0.3514 versus +0.2182. Agreement on the move does not establish score accuracy.
- `reserves-05`: even 3,000 differed from 8,000 by 0.0854, despite agreeing on
  the knight drop. Deeper search is not automatically a definitive evaluator.

## Follow-up: search both candidate moves

For five deliberately selected move disagreements, apply each alternative with
proper cross-board transfers, then search the resulting position from the
opponent's seat for 8,000 nodes. This adds ten searches. The first four cases
had the largest 100/800-node value discrepancies among move disagreements;
the fifth explicitly checks the opening `...Ne5` versus `...Nb4` choice.

Values below are flipped to the parent mover's team, so **higher is better**.
They use the table's current static-offset correction. This common child
horizon is useful for comparison but is still an imperfect engine assessment;
it is not an independently measured loss in playing strength.

| Position | Alternatives: child Q from parent team | Preferred child | Child Q gap | 800-node root choice | 8,000-node root choice |
| --- | --- | --- | ---: | --- | --- |
| `reserves-08` | `g2f3` +0.9464; `g2g1` +0.9367 | `g2f3` | 0.0097 | `g2g1` | `g2f3` |
| `reserves-07` | `P@d3` +0.6467; `P@f7` +0.6957 | `P@f7` | 0.0490 | `P@d3` | `P@d3` |
| `reserves-04` | `e6d5` +0.5900; `e7d6` +0.6309 | `e7d6` | 0.0410 | `e7d6` | `e7d6` |
| `reserves-01` | `P@b2` +0.6577; `P@c3` +0.5621 | `P@b2` | 0.0956 | `P@c3` | `P@b2` |
| `opening-07` | `c6b4` +0.0005; `c6e5` +0.0240 | `c6e5` | 0.0235 | `c6e5` | `c6b4` |

The opening alternatives are close, whereas the `P@b2` / `P@c3` decision has a
0.0956 Q gap in this follow-up. In `reserves-07`, the child comparison instead
prefers the 100-node root choice `P@f7` over the original 8,000-node choice
`P@d3`, by 0.0490 Q. The opening child comparison also reverses the 8,000-node
root preference. Consequently, raw best-move agreement cannot be read as a
blunder rate, and even the deeper reference is not stable across search
horizons. Position-dependent offset correction is another source of uncertainty
when comparing different children. These selected case studies support deeper
refinement of close decisions; they do not establish a universal gap threshold.

## Winning-mate probe: 60 cases, 1,800 calls

The 24 FICS cases plus 36 selected-board configurations drawn from 19 unique
literal dual FENs in the pinned upstream mate regressions. Three repeats of ten
budgets, with a ten-second safety deadline per call. No call hit that deadline,
no call changed its input board, and every returned proof had a legal move on
the required board. Proof outcomes and moves were identical across the three
repeats. The probe did not load or run the neural network.

The 300,000-node reference proved a win in **9 cases**. The other 51 are
**unproven**, not certified non-mates. This tests a curated regression set, not
general mate recall. Multiple selected-board configurations share a position.

| Mate-probe budget | Reference proofs retained | Median ms | 95th-percentile ms | Worst ms |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 6/9 | 0.043 | 0.151 | 2.40 |
| 300 | 6/9 | 0.060 | 0.200 | 7.05 |
| 1,000 | 8/9 | 0.144 | 0.415 | 19.81 |
| 2,000 | 8/9 | 0.270 | 0.738 | 44.63 |
| 3,000 | 8/9 | 0.384 | 1.058 | 61.32 |
| 8,000 | 8/9 | 0.868 | 2.401 | 170.15 |
| 10,000 | 8/9 | 1.069 | 3.272 | 211.45 |
| 30,000 | 8/9 | 1.973 | 8.619 | 588.05 |
| 100,000 | 9/9 | 4.596 | 26.326 | 1,506.85 |
| 300,000 | 9/9 | 13.957 | 66.470 | 3,013.23 |

The extra proof above 30,000 is a `Q@g8` mate on board B, with a simultaneous
`a7a6` move on A under the no-time-advantage rules. It took approximately 2.9 ms
at 100,000. The slowest probe was a separate intentionally difficult deadline
regression that remained unproven. High mate budgets are usually cheap but do
have a runtime tail; a separately tested wall-time cap would be sensible.

These are direct calls to `Agent::find_root_mate` in the clean local Hivemind
source at commit `5508ba9`, linked to its existing static library. The library
and helper hashes are recorded in `mate-provenance.json`. This is a separate
build from the bundled UCI engine used in the neural sweep. Node allowances are
the mate solver's units and may be distributed among multiple subprobes; they
are not interchangeable with MCTS nodes. The forced-loss scanner and in-tree
MCTS proof mechanisms were not independently swept here.

## What this means for the table

800 nodes is about **3.6× faster** than 3,000 in the measured median, but it
does not provide enough evidence to declare the trickiest move when candidate
values are close. A practical design is a coarse first pass followed by deeper
candidate/leaf refinement, with quality labels on saved values. A value gap
around 0.10 Q or less is a reasonable trigger for extra search in this pilot,
not a statistically validated confidence bound. Strong tactical signals or
instability as the budget grows should also trigger refinement.

Using 3,000 nodes for the root and four candidate positions, and 800 for sixteen
reply leaves, projects about **2.2×** the throughput of 3,000 everywhere using
these medians. Using 800 everywhere projects about **3.6×**, before caching,
policy computation and adaptive refinement. These are arithmetic estimates,
not measured end-to-end builder speeds. Both colour columns already share the
same evaluated tree.

Do not reduce mate-probe work in lockstep with neural nodes. In the inspected
source, the root mate allowance scales as `clamp(10 × MCTS nodes, 2000, 100000)`.
The installed UCI interface has no independent mate-budget knob; decoupling it
requires an engine/interface change before the proposed 800/100,000 combination
can be deployed. No such change was made by this benchmark.

## Reproduction and records

See [the harness guide](../BUGHOUSE_BUDGETS.md). `cases.json` contains exact dual
FENs and FICS game IDs. `sampling.json` pins the source sample and random seed.
`run-0.json` and `run-1.json` identify the bundled executable, model and settings.
`search-0.jsonl` and `search-1.jsonl` contain all 144 primary observations;
`summary.json` contains their aggregate statistics. `environment.json` records
the CPU and job limits. `mate-cases.json`, `mates.jsonl.gz` and
`mate-summary.json` preserve the direct-solver experiment. `rankings/` stores
the ten child positions, all 20 static/search observations, engine manifests
and the derived comparison. Mixed shard counts only partitioned disjoint
cases; validation checks every case and budget exactly once.

The sample is small, non-population-weighted and limited to the installed model
and these no-clock rules. A deeper reference is still fallible. Nothing here
establishes Elo, real-game win calibration, or a universal safe node threshold.
