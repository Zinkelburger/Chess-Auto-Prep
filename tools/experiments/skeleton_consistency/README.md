# Skeleton-consistency experiment

Question: given only a user's *skeleton* lines (e.g. the Benko mainline
`1.d4 Nf6 2.c4 c5 3.d5 b5 4.cxb5 a6 5.bxa6 e6`), which scoring signal makes
the generator rediscover the "consistent" reply when White deviates
(`2.Nf3 c5`, `2.Nf3 c5 3.d5 b5`, `2.Bf4 c5`, `2.Bf4 c5 3.e3 Qb6`, `2.e3 c5`,
`4.Qxd4 Nc6`)?

Standalone Python; not part of the app or CI. Uses the app's own assets:
Stockfish (`~/.local/share/com.example.chess_auto_prep/stockfish-linux`),
`assets/maia3_simplified.onnx` + `assets/data/all_moves_maia3_reversed.json`
(Maia-3 encoding mirrors `tree_builder/src/maia.c`), and the public ChessDB
API. Everything is cached in `cache.db` next to the scripts.

```
python3 -m venv venv && ./venv/bin/pip install chess numpy onnxruntime
./venv/bin/python experiment.py    # round 1: engine / expectimax / transfer / reach / pawn-structure
./venv/bin/python experiment2.py   # round 2: transfer with distance cap, shadow distance, opponent-error
```

`onnxruntime` segfaults loading `maia3_simplified.onnx` with graph
optimizations on; `harness.py` disables them.

Findings are summarised in `docs/REPERTOIRE_PLANNING.md` (section
"What the experiment showed"); raw tables are in `results_round*.txt`.
