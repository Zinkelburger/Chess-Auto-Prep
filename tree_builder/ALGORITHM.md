# Pure expectimax

The authoritative shared mathematical contract is [docs/ALGORITHM.md](../docs/ALGORITHM.md).

`src/pure_search.c` owns exhaustive finite-horizon construction, Bellman backup,
and the shared maximizing scorer. `src/san_convert.c` adapts chesslib legal moves
and terminal rules. `src/tree.c` dispatches the standard build mode to Pure;
its older expansion helpers are retained for the separate database modes.

C uses Lichess master frequencies by default, with Maia off-book. Pass
`--maia-only` to deselect master targeting. It does not use the app's local TWIC
book. Source identity and the Pure model settings are persisted for resume.

Build and test through the repository's bounded runner:

```
scripts/ci.sh with -- make -C tree_builder -j2
scripts/ci.sh with -- make -C tree_builder test-pure
```

`NO_MAIA=1` supports offline tests, including the scripted UCI builder test.
A production search reaching an off-book opponent node requires a working Maia
model. For stronger engine evaluations, rebuild with a larger `--eval-depth`;
Pure does not claim that a post-hoc check can certify omitted candidates.
