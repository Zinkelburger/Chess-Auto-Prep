# Pure expectimax

The authoritative shared mathematical contract is [docs/ALGORITHM.md](../docs/ALGORITHM.md).

`src/pure_search.c` owns exhaustive finite-horizon construction, Bellman backup,
and the shared maximizing scorer. `src/san_convert.c` adapts chesslib legal moves
and terminal rules. `src/tree.c` dispatches the standard build mode to Pure;
its older expansion helpers are retained for the separate database modes.

Stockfish expectimax (the default build mode) always uses Maia for every
opponent position: `main.c` forces `maia_only` on and master games off for it,
whatever `-m`/`--masters`, `--lichess` or a restored `--resume` setting says,
and `pure_tree_build` records `opponent_book_source: "none"`. Master and Lichess
frequencies feed only the separate database build modes; none of them reads the
app's local TWIC book. The Pure model settings, search method and reply cut
are persisted, and a resume must match them.

`--search fast` (alias `rolling`) runs the approximate receding four-ply
lookahead in `rolling_build`; see
[Fast search](../docs/ALGORITHM.md#fast-search-c-builder-and-mcp-only).

Build and test through the repository's bounded runner:

```
scripts/ci.sh with -- make -C tree_builder -j2
scripts/ci.sh with -- make -C tree_builder test-pure
```

`NO_MAIA=1` supports offline tests, including the scripted UCI builder test.
A production search reaching an off-book opponent node requires a working Maia
model. For stronger engine evaluations, rebuild with a larger `--eval-depth`;
Pure does not claim that a post-hoc check can certify omitted candidates.
