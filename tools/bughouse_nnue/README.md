# A single-board bughouse NNUE

The site's `/bughouse` board can run Fairy-Stockfish as `pocketknight`: chess
with drops, where a capture leaves the board for the partner and a drop spends
what is in hand. It is fast — millions of positions a second, natively; hundreds
of thousands in the browser — but its evaluation is the hand-written one, and the
crazyhouse NNUE was rejected because it never saw material leave the game. This
package builds the training data for an evaluation that has: an NNUE for
pocketknight, trained on how real bughouse games turned out.

## Why outcomes, and why so few positions per game

The eval is trained the way AlphaGo's value network was (Silver et al., *Nature*
2016): regress a win probability on the game result. There is no other ground
truth for "the right eval" than who won, and in bughouse the result is the one
signal that knows pieces arrive — nothing in a single-board search does. The
hands in each record are real: the archive is replayed two boards at a time, so a
knight in Black's hand got there because the partner took one.

AlphaGo also found that regressing outcomes on *every* position of a game
memorises the game (successive positions share one label; 0.37 test error
against 0.19 on the training set) and fixed it by sampling one position per
game. NNUE nets are far smaller, so `extract` takes a handful per board
(`--per-board`, default 6), fewer from the board the game did not end on.

CrazyAra (Czech et al. 2019) trained a crazyhouse value head the same way on
570k lichess games of players rated 2000+ and needed to down-weight the value
loss to avoid overfitting; this corpus is 3.6M games, two boards each.

## Steps

All from `tools/`:

```
python3 -m bughouse_nnue setup                 # builds the tools (~3 min), fetches the trainer
python3 -m bughouse_nnue extract               # the whole archive; ~45 min on 22 cores
python3 -m bughouse_nnue convert               # -> dataset/pocketknight.bin + .val.bin
python3 -m bughouse_nnue evaluate              # baseline: the hand-written eval
python3 -m bughouse_nnue status
```

`extract --only 2017 --games 4000` is the quick version. Each year writes a
`stats.json` with how games ended and which pieces arrived when; `stats.json`
at the top sums them.

Optional, for comparing against the Stockfish-style blend of search score and
result: `score --depth 4` fills the score field with a pocketknight search
(hand-written eval, so it knows nothing about arrivals), then
`convert --scored --name pocketknight-scored`.

## Training

Needs a CUDA GPU; the trainer's data loader has no CPU path. Copy the two
`.bin` files, `toolchain/trainer-config/` and `train.sh` to the GPU machine:

```
bash train.sh pocketknight.bin pocketknight.val.bin --config trainer-config --lambda 0.0 --epochs 20
```

`--lambda 0.0` is pure outcomes (AlphaGo). A blend such as `--lambda 0.3` needs
the scored dataset. One epoch is 20M positions; the trainer wiki suggests at
least 100M positions of data, so expect many passes over ~30M records and watch
the validation loss for the point where it stops improving.

Kaggle gives a free GPU (30 h/week in 12 h sessions); `train.sh` has the recipe.

## The gate

```
python3 -m bughouse_nnue evaluate --net nets/pocketknight.nnue
python3 -m bughouse_nnue evaluate                       # hand-written eval
python3 -m bughouse_nnue evaluate --net crazyhouse.nnue --variant crazyhouse
```

Same held-out positions (games `extract` set aside by game number), same
question: which team won? *Sign accuracy* is AlphaGo's value-accuracy-sign
(draws left out); *log loss* is of `sigmoid(score / scale)` with the scale
fitted per eval so units do not matter; chance is 0.693. A net that does not
beat the hand-written eval here is not worth loading on the site.

Beyond that: the 14 FICS opening positions in
`tools/experiments/compare_bughouse_engines.py`, and your own eyes.

## Loading the net

Fairy-Stockfish takes it with `setoption name EvalFile value <net>` and
`Use NNUE pure`. **The file name must start with `pocketknight`**: the engine
restricts nets to their variant by name and otherwise keeps the classical eval
without saying so (`evaluate.cpp`, `NNUE::init`). `train.sh` and `evaluate`
both enforce this. The site's browser build (`fsf_14.js`, lichess's
stockfish-web API) takes the bytes with `setNnueBuffer(net, 0)` after
`UCI_Variant` is set, as the old crazyhouse page did.

## Verified without a GPU (Oct 15 2026)

- The trainer's own C++ data loader reads the packed sample back with the
  right side to move, outcome, score and feature count for every position,
  including the pieces in hand — once `PIECE_COUNT` is raised. The tools write
  34 (one board's starting material) but a bughouse board also holds what the
  partner sent: 22% of sample positions exceed 34 pieces counting the hands,
  up to 50, and the loader corrupts memory past its limit. `setup` now writes
  `PIECE_COUNT 64` (`toolchain.MAX_PIECES`).
- An untrained net written by the trainer's serializer (CPU PyTorch, no CUDA)
  loads and searches in the native Fairy-Stockfish 151026 and in the site's
  FSF 14 browser build.

## Pins

`toolchain.py` pins both upstreams:

- variant-nnue-tools `445b53c4` (2026-09-25) — Fairy-Stockfish 151026 with the
  data commands. Its packed format keeps placement, hands, side to move, ply and
  result; castling rights and the promoted-piece marker do not round-trip, which
  the NNUE features never see anyway.
- variant-nnue-pytorch `b15df38a` (2026-06-30) — `--lambda`, `HalfKAv2^`
  features, 20M-position epochs.
