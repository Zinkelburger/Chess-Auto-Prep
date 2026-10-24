# A single-board bughouse NNUE

Fairy-Stockfish's `pocketknight` variant is chess with drops, where a capture
leaves the board for the partner and a drop spends what is in hand. It is fast
— millions of positions a second, natively; hundreds of thousands in a browser
build — but its evaluation is the hand-written one, and the crazyhouse NNUE
never saw material leave the game. This package builds the training data for
an evaluation that has: an NNUE for pocketknight, trained on how real bughouse
games turned out. Nothing in the app or on the website loads such a net; the
website's `/bughouse` board runs Lichess's crazyhouse net.

## What the net learns from

The eval is a win-probability regression on game results, the way a value
network is trained (Silver et al., *Nature* 2016): there is no other ground
truth for "the right eval" than who won, and in bughouse the result is the one
signal that knows pieces arrive — nothing in a single-board search does. The
hands in each record are real: the archive is replayed two boards at a time, so a
knight in Black's hand got there because the partner took one.

Three choices keep the label honest:

- **Only games that ended in checkmate** (`--terminations`, default
  `checkmated`). A game lost on time or by disconnection says little about the
  positions in it, and a resignation is a guess; mate is the one result the
  position itself decides. On a 2017 sample that is 48% of decisive rated games.
- **Only quiet positions** (`--any-ply` turns this off): not in check, and the
  move played was not a capture. The engine only asks the net about quiet
  positions — captures and checks are resolved by the search first — and a
  static value for the middle of a tactic is a bad target. Stockfish's trainer
  skips the same positions; this one does the skipping in `extract` because
  the variant trainer's own skip is a no-op. Half of bughouse positions go.
- **A few positions per board** (`--per-board`, default 6, fewer from the board
  the game did not end on). AlphaGo found that regressing outcomes on every
  position of a game memorises the game (successive positions share one label;
  0.37 test error against 0.19 on the training set) and fixed it by sampling
  one position per game. Note that AlphaGo's value net was trained on 30M
  *self-play* games, one position each, after the human-game version overfit;
  the precedent for a value function from human outcomes is CrazyAra (Czech et
  al. 2019), a crazyhouse value head on 570k lichess games, which had to weight
  the value loss at 0.01 of the policy loss to stop it memorising. This net has
  no policy loss to lean on, and its feature transformer (864 planes × 64 king
  squares × 512) has more weights than AlphaGo's value net had. Six per board
  is a guess; the validation loss is what decides, and `train.sh` serializes
  the epoch where it was lowest.

With those filters the archive yields on the order of 7 positions per used
game, roughly 8M positions in all. The hands are what make them worth more
than the same number of crazyhouse positions.

`--lambda` is the other lever. 0 is pure outcomes; 1 is the search score; a
blend is what Stockfish uses, because pure-outcome nets come out flat (a
position the net can only call 60% is +0.4 pawns) and the search's pruning
margins are tuned to classical eval magnitudes. Which works best here is an
experiment, not a principle: `score` the records, then train
`--lambda 0,0.5,1` in one session and let `match` decide.

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

`score --depth 4` fills the score field with a pocketknight search
(hand-written eval, so it knows nothing about arrivals); then
`convert --scored` packs the scored records, and any `--lambda` can be
trained from the one dataset. Without it only `--lambda 0` is meaningful.

## Training

Needs a CUDA GPU; the trainer's data loader has no CPU path. Copy the two
`.bin` files, `toolchain/trainer-config/` and `train.sh` to the GPU machine:

```
bash train.sh pocketknight.bin pocketknight.val.bin --config trainer-config --lambda 0,0.5,1 --epochs 10
```

`--lambda 0.0` is pure outcomes; a blend needs the scored dataset; a comma
list trains one net per value in turn (`pocketknight-lambda0.5.nnue`, …).
One epoch is 20M positions drawn with the trainer's default random skipping,
so ten epochs see each of ~8M records about ten times; the trainer wiki
suggests at least 100M positions of data for chess. Every epoch is
checkpointed, the per-epoch validation losses are printed at the end, and the
epoch with the lowest one is the net that is written — not the last.

Kaggle gives a free GPU (30 h/week in 12 h sessions). `bundle` writes one
folder to upload as a Kaggle dataset — the two `.bin` files, `trainer-config/`,
`train.sh` and a notebook whose single cell runs it — and prints the clicks:

```
python3 -m bughouse_nnue bundle --args "--epochs 2 --epoch-size 2000000 --val-size 100000"
```

Those `--args` are the smoke test on the 17k-position sample: two short epochs,
enough to prove the training loop, loader and serializer agree on the GPU
before the ~45 min full extraction. Leave `--args` off for a real run.

The machine this was written on has an Intel Arc iGPU (Meteor Lake); it is no
use here, because the trainer's feature transformer is hand-written CUDA run
through CuPy (`feature_transformer.py` asserts every tensor `is_cuda`), not
something PyTorch's Intel XPU backend can run.

## Self-play: the second source of games

```
python3 -m bughouse_nnue selfplay --games 20000 --nodes 10000        # hand-written eval
python3 -m bughouse_nnue selfplay --games 20000 --net nets/pocketknight-x.nnue
python3 -m bughouse_nnue convert --source selfplay   # -> dataset/pocketknight-selfplay.bin
```

Four single-board searches play a whole bughouse game, two boards moving in
turn, captures crossing to the partner's hand exactly as `extract` replays
them. Games start from the first 10 plies per board of real archive games
(`--opening-plies`; `--random-plies` is the fallback), the hash is cleared
between games, and 8 quiet positions per board are kept with the search score
*and* the result, so any `--lambda` works (`--per-board 0` keeps everything).

It is the stage that repeats: a net trained on it plays the next round. What
it cannot do is replace the archive on the first round: the games are played
by the hand-written eval, which knows nothing about pieces arriving, so its
results describe how that eval plays. Two identical engines at fixed nodes
also produce near coin-flip results, so for self-play data the search score
(`--lambda` above 0) carries most of the information; Stockfish's self-play
data was labelled with search scores for that reason. The game it plays is
not quite bughouse either — no clock, boards in lockstep, and a player sits
only when nothing else is legal (a mate a dropped piece could block is not
mate; they wait for the partner's piece) — which is fine for "what is the
best move here" and not for anything about tempo. Fewer openings than games
means a reused opening gets two random plies a board after it, so no game
repeats; a game that breaks is counted as `error` and the run goes on.

Measured: about 0.5 games/s per core at 5000 nodes a move, ~60 plies per
board.

## The gate: a match

```
python3 -m bughouse_nnue match --net-one nets/pocketknight-lambda0.5.nnue --games 400
python3 -m bughouse_nnue match --net-one A.nnue --net-two B.nnue --games 400
```

The question an engine is asked is "what is the best move here", and the only
test of that is play: one team's two searches run the net, the other team's
run the hand-written eval (or another net), same fixed nodes, every archive
opening played twice with the teams swapped. The result is a score, an Elo
difference with a 95% interval, and a likelihood of superiority, appended to
`nets/matches.jsonl`. 400 games at 10000 nodes is about 15 minutes on 22
cores and resolves a 50 Elo difference. A net that does not win here is not
worth loading, whatever its validation loss says.

```
python3 -m bughouse_nnue evaluate --net nets/pocketknight.nnue
python3 -m bughouse_nnue evaluate                       # hand-written eval
```

`evaluate` is the cheaper, weaker check: on held-out archive positions, did
the eval's sign pick the winner, and the log loss of `sigmoid(score / scale)`
with the scale fitted per eval (chance 0.693). It measures the training
objective, so a trained net passes it almost by construction; its use is
catching a broken net (a wrong feature set, an unloaded file) before a match
is spent on it, and the fitted `scale` says how flat the net's eval is next
to the hand-written one.

## Loading the net

Fairy-Stockfish takes it with `setoption name EvalFile value <net>` and
`Use NNUE pure`. **The file name must start with `pocketknight`**: the engine
restricts nets to their variant by name and otherwise keeps the classical eval
without saying so (`evaluate.cpp`, `NNUE::init`). `train.sh` and `evaluate`
both enforce this. Lichess's FSF 14 browser build (`fsf_14.js`, the
stockfish-web API) takes the bytes with `setNnueBuffer(net, 0)` after
`UCI_Variant` is set.

## Verified without a GPU

- The trainer's own C++ data loader reads the packed sample back with the
  right side to move, outcome, score and feature count for every position,
  including the pieces in hand — once `PIECE_COUNT` is raised. The tools write
  34 (one board's starting material) but a bughouse board also holds what the
  partner sent: 22% of sample positions exceed 34 pieces counting the hands,
  up to 50, and the loader corrupts memory past its limit, so `setup` writes
  `PIECE_COUNT 64` (`toolchain.MAX_PIECES`).
- An untrained net written by the trainer's serializer (CPU PyTorch, no CUDA)
  loads and searches in the native Fairy-Stockfish 151026 and in Lichess's
  FSF 14 browser build.

## Pins

`toolchain.py` pins both upstreams:

- variant-nnue-tools `445b53c4` (2026-09-25) — Fairy-Stockfish 151026 with the
  data commands. Its packed format keeps placement, hands, side to move, ply and
  result; castling rights and the promoted-piece marker do not round-trip, which
  the NNUE features never see anyway.
- variant-nnue-pytorch `b15df38a` (2026-06-30) — `--lambda`, `HalfKAv2^`
  features, 20M-position epochs.
