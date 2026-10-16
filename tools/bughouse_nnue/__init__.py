"""Training data and tooling for a single-board bughouse NNUE.

The site's bughouse board runs Fairy-Stockfish as `pocketknight`: chess with
drops, where a capture leaves the board (it goes to the partner) and a drop
only spends what is in hand.  Its evaluation is the hand-written one, and
the crazyhouse NNUE was rejected because it never saw material leave the
game.  This package builds the thing that was missing: an NNUE for those
rules, trained the way AlphaGo's value network was (Silver et al. 2016,
regression of a win probability on game outcomes) from the FICS archive the
opening book already replays.

The pipeline, each step a `python3 -m bughouse_nnue <command>` from `tools/`:

    setup      clone and build Fairy-Stockfish's variant-nnue-tools (the data
               converter, which is a full engine) and fetch the trainer, both
               pinned; write the trainer's variant.h/variant.py for pocketknight
    extract    replay the archive two boards at a time, sample a few positions
               per board, label each with its team's result from the side to
               move's point of view, and write the trainer's plain-text format
    score      optional: add a shallow pocketknight search score to each
               position, so the trainer's result/score blend can be compared
    convert    interleave the per-year files and pack them to the `.bin` the
               trainer reads
    evaluate   how well an evaluation predicts held-out outcomes, for the
               hand-written eval, the crazyhouse net and any trained net

Training itself needs a CUDA GPU (the trainer's data loader has no CPU
path); `train.sh` and README.md cover Kaggle's free GPU and a rented box.

Sampling is a few positions per board, not every position, because AlphaGo
found that regressing outcomes on every position of a game memorises the
game (successive positions share one label; test error 0.37 against 0.19 on
the training set) and fixed it by sampling one position per game.  NNUE nets
are far smaller than that network, so a handful per board is the compromise;
`--per-board` sets it.

Data lives under `~/.local/share/chess-prep/bughouse-nnue/` beside the
archive, never in the repo or its assets (`BUGHOUSE_NNUE_HOME` relocates it).
"""
