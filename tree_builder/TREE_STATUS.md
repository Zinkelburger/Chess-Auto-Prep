# `scandi_12ply` tree status (2026-05-29)

Short answer: the tree is **not corrupt**, but it is **meaningfully incomplete**. `build_complete: false` and ~3.6k unexplored frontier nodes mean BFS stopped before the queue finished. `max_depth: 12` only means *some* path reached 12 plies, not that the tree is fully expanded to that depth. Re-run with the same `-d 12` **resumes** BFS from frontier leaves (reload footgun fixed in `main.c`).

---

## Current file state

| Field | Value |
|--------|--------|
| `total_nodes` | 7,154 |
| `max_depth` (serialized `max_depth_reached`) | 12 |
| `build_complete` | `false` |
| `config` | `min_probability` 0.0001, `max_depth` 12, Maia opponent moves (default) |
| `build_performance` | 221.4 s, 8 threads, eval depth 14 |
| `branching_factor` (metadata) | ~2.1 (`total_nodes^(1/max_depth)`) |

Node counts by depth (0–12): 1, 3, 4, 8, 14, 37, 67, 174, 402, 885, 2034, 3086, **439** at depth 12.

Structural audit of `scandi_12ply.tree.json`:

- **3,610** nodes are frontier leaves: `explored: false`, no `children` (pending BFS work).
  - **2,947** at depth 11, **439** at depth 12, remainder at 7/9/10.
- **557** terminal leaves with `explored: true` (depth cap, prune, transposition, etc.).
- Most frontier nodes have `cumulative_probability` well above `0.0001` (max ~0.021); they are not merely below the min-prob cutoff.

Exported `scandi_12ply.pgn`: 100 games, header matches the 7,154-node / 221 s build stats.

---

## What `build_complete` means

Set at the end of `tree_build()` in `tree.c`:

```1730:1731:tree_builder/src/tree.c
    tree->build_complete = tree->is_building;
    tree->is_building = false;
```

- **`true`**: the BFS loop exited with `is_building` still true — typically the FIFO queue drained (`build_queue_pop` returned `NULL`).
- **`false`**: `is_building` was cleared before the queue finished — via `tree_stop_build()` (SIGINT/SIGTERM handler in `main.c`), OOM on queue push, or the fast-resume path with zero frontier.

It does **not** mean “JSON is invalid.” It means “builder did not finish the intended BFS expansion,” which matches the 3,610 frontier nodes.

`max_depth_reached` is updated whenever a child is attached (`tree.c`); it is the **deepest node present**, not “every line was built to 12 plies.”

---

## Intended BFS behavior (`ALGORITHM.md`)

- Single FIFO queue; shallow plies are expanded before deeper work (`ALGORITHM.md`, “BFS and interrupted builds”).
- Stop expanding a dequeued node at `depth >= max_depth` (marks `explored`, no children) — `build_process_node()` ~1502–1507.
- Resume enqueues only frontier leaves (`resume_prepare_frontier()` ~689–710): no children and not explored.

A **complete** 12-ply build should end with `build_complete: true` and no unexplored frontier above the min-probability gate (except nodes never created because cumP was below threshold at child creation).

---

## Was this run interrupted or “natural”?

From artifacts alone:

| Evidence | Implication |
|----------|-------------|
| `build_complete: false` | BFS did not finish normally. |
| 3,610 unexplored frontiers | Queue still had work; tree is sparse at ply 11–12. |
| 221 s wall time | Consistent with a **partial** build, not an April-scale (~118k node) completion. |
| PGN exists | Either (a) build phase ended without `g_interrupted` before stage 2, or (b) a **later** run loaded the JSON and ran repertoire export only. |

`main.c` skips stages 2–4 when `g_interrupted` is set after stage 1 (`~1428`). So PGN does not by itself prove the build phase completed — only that export ran at least once afterward.

`tree_stop_build()` is only called from the signal handler (`main.c` ~259–262). An in-flight stop after children were linked but before enqueue would leave frontier nodes (`build_opponent_move` / `build_our_move` enqueue at ~1479 / ~1076).

---

## Reload / resume (`main.c`) — fixed 2026-05-29

When an on-disk tree is loaded, stage 1 skips building **only** when `build_complete` is true. If `build_complete` is false, building always resumes from unexplored frontier leaves, even when `max_depth_reached >=` CLI `-d`.

Previously, `max_depth_reached >= max_depth` incorrectly set `needs_build = false` for incomplete trees despite thousands of frontier nodes.

`--build-now` / `--skip-build` still skip building entirely (export-only).

---

## PGN vs tree coverage

- **Tree small → PGN thin:** Most opponent branches stop at unexplored frontiers; `extract_lines()` only walks existing children (`repertoire.c`). Unexpanded subtrees cannot appear in export.
- **Repertoire selection bug (winner-only traversal):** Fixed in uncommitted `repertoire.c` (traverse all our-move children for move list). That affects **which our-move FENs get repertoire entries**, not whether opponent lines exist in the tree. Missing lines from a 7k sparse tree are primarily **missing nodes**, not only the export bug.
- Re-export alone on this file **does not** add positions the tree never built.

---

## Comparison to April ~118k-node run

Not stored in-repo here. The May tree’s ~2.1 branching factor and depth-11 frontier mass indicate **early stop of BFS**, not a finished 12-ply Scandinavian map. Same `-p 0.0001` / `-d 12` on a completed build should yield far more than 7k nodes (order of magnitude more if expansion ran to completion).

---

## Recommendations

1. **Do not treat this tree as a full 12-ply Scandinavian repertoire.** It is a shallow, uneven snapshot with ply-11 frontiers still open.
2. **Re-run with the same basename and `-d 12` to resume** — incomplete trees (`build_complete: false`) continue BFS from frontier leaves.
3. **To finish the build (pick one):**
   - **Resume (preferred):** same base name and `-d 12`; or
   - **Rename or remove** `scandi_12ply.tree.json` and run a full build (same FEN/moves/flags); or
   - **Go deeper:** use `-d 13` (or higher) if you want expansion past the current cap.
4. **PGN:** After a complete build (`build_complete: true`, frontier count ~0), re-run export; apply the `repertoire.c` fix if you need all our-move candidates represented in line extraction.
5. **Verify completion:** `build_complete: true` in JSON; frontier audit shows no unexplored nodes above min-prob; node count in the same ballpark as a prior complete run for the same settings.

---

## Code references (quick index)

| Topic | Location |
|--------|----------|
| `build_complete` assignment | `tree_builder/src/tree.c` ~1730 |
| BFS loop / queue drain | `tree_builder/src/tree.c` ~1700–1719 |
| Frontier resume | `tree_builder/src/tree.c` ~689–710, ~1665–1668 |
| Depth / min-prob skip | `tree_builder/src/tree.c` ~1502–1512 |
| Reload skip logic | `tree_builder/src/main.c` ~1075–1085 |
| SIGINT → `tree_stop_build` | `tree_builder/src/main.c` ~259–262 |
| Serialize `max_depth` / `build_complete` | `tree_builder/src/serialization.c` ~149–150, ~571–578 |
| BFS / interrupt design note | `tree_builder/ALGORITHM.md` ~744–750 |
