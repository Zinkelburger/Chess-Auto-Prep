# Recent Games home + app-wide breadcrumb navigation — Design Note

**Status:** design only (2026-07-28). Nothing implemented yet.

Two connected features:

1. **A "Games" home page** — the app opens on a chess.com-style list of your
   recent games (time control, players + ratings, result, accuracy, moves,
   date, Review button). Clicking Review opens the existing PGN viewer + game
   analysis. Each game also shows where you left your repertoire, with a
   clickable link that opens the repertoire at that line.
2. **A breadcrumb history stack for the whole app** — e.g.
   `Tactics ▸ Game BigMan vs MaouTanner ▸ Repertoire "Dynamic 1.d4"`.
   Clicking a top-level destination resets the stack; clicking a crumb pops
   back to it with its state restored. Works identically on Linux / Windows /
   macOS (it is pure in-app navigation).

Companion docs: [`GAMES_DRIVEN_REPERTOIRE.md`](GAMES_DRIVEN_REPERTOIRE.md)
(shared games library + draft/merge flow this builds on),
[`COMPONENT_MAP.md`](COMPONENT_MAP.md).

---

## Inventory: what already exists (verified 2026-07-28)

| Need | Status today |
|---|---|
| Download + cache my games (both platforms) | **Exists.** `GamesLibraryService` (`lib/services/games_library/`) — per-(platform, username) PGN cache, 12 h TTL, verified chess.com + Lichess fetchers, `GameSelection` filters. Only consumer so far is the draft flow. |
| Per-game metadata (players, ratings, result, date, speed) | **Exists** via `GameRecord` (`game_filter.dart`) + PGN headers. Missing: move count (trivial to compute), accuracy (not fetched anywhere). |
| Full game review (blunders, eval graph, ACPL) | **Exists.** `GameAnalysisController.analyzeGame()` — batch engine pass, Lichess-style win%-swing classification (0.30/0.20/0.10), Maia "interesting" moves, `[%eval]` persistence + zero-engine cached restore on every game switch. |
| 0–100 accuracy score | **Missing.** Only ACPL + classification counts exist. All ingredients (per-move win chances) already computed. |
| Open the PGN viewer on a specific game | **Partial.** `OpenPgnViewer{pgnPath, sliceFen}` handoff exists; no game-id targeting, no auto-analyze flag. |
| Game-vs-repertoire deviation | **Partial.** `RepertoireDiff` (`lib/services/games_repertoire/repertoire_diff.dart`) classifies my-deviation / opponent-deviation / beyond-book — but only on an *aggregate* `OpeningTree`; per-game attribution ("you left book at move 12 of THIS game") does not exist. Strict SAN-prefix matching, no transpositions. |
| Deep link into the repertoire at a line | **Exists.** `AppState.switchToBuilder(repertoirePath, lineId, moveSequence)` → `OpenBuilder` handoff → `navigateToLineMove` (same mechanism audit findings use). |
| "My White repertoire / my Black repertoire" designation | **Missing.** Files carry `// Color:` but nothing says "this is *mine*". No repertoire path is persisted anywhere. |
| App navigation history | **Missing.** Six `AppMode`s in an `IndexedStack`, switched via `AppState.setMode`/`handOff` (take-once `PendingHandoff`), 12 existing cross-screen handoffs, zero history. Note: `lib/core/navigation_stack.dart` + `lib/widgets/navigation_trail.dart` are an existing (currently dead/board-position-scoped) stack + chip-trail pair — right *shape*, wrong *scope*. |

The project is therefore mostly **wiring existing engines to a new front
door**, not building new infrastructure.

---

## Part 1 — Breadcrumb navigation (build this first)

This is the enabler for everything else, and it is nearly free because of an
existing property of the app: **`PendingHandoff` is already a serializable
"screen + payload" route object.** Every cross-screen jump in the app is
either a bare `setMode` or a `handOff(PendingHandoff)`. A history stack only
needs to *record* those.

### `AppHistory` (new, `lib/core/app_history.dart`)

A `ChangeNotifier` (with `SafeChangeNotifier`) owned next to `AppState` in the
root `MultiProvider`. Stack of:

```dart
class AppHistoryEntry {
  final AppMode mode;           // breadcrumb root identity
  final PendingHandoff? handoff; // null for a bare mode root
  final String label;           // "Tactics", "Game BigMan vs MaouTanner",
                                // "Repertoire \"Dynamic 1.d4\""
}
```

API:

- `resetTo(AppMode mode)` — what the mode menu calls. Clears the stack to one
  root entry (label = mode display name) and calls `appState.setMode`.
  This is the user's "click Tactics and erase my history".
- `push(String label, PendingHandoff handoff)` — appends an entry and calls
  `appState.handOff(handoff)`. Every existing `switchToX` producer call site
  migrates to this (12 sites); the *consumer* screens do not change at all —
  they keep their existing take-once listeners.
- `popTo(int index)` — breadcrumb click. Truncates the stack after `index`,
  then **re-delivers** that entry: `handOff(entry.handoff)` if it has one,
  else `setMode(entry.mode)`. Consumers already restore themselves from a
  re-fired handoff (reload file, reopen line), so no per-screen work.
- `back()` — `popTo(length - 2)`; no-op at root.

Rules:

- Pushing while not at the top never happens (`popTo` truncates first), so the
  stack is always linear — no forward history in v1.
- Cap depth (reuse the 8-entry cap idea from `NavigationStack`); drop-oldest.
- Respect the existing generation lock: crumb clicks disabled while
  `AppState.isRepertoireGenerating`, same as `AppModeMenuButton` today.
- A `setMode`/`handOff` that does **not** go through `AppHistory` (there
  should be none after migration) resets the stack defensively to a single
  root, so the trail can never lie.

### The breadcrumb bar (new, `lib/widgets/app_breadcrumb_bar.dart`)

One global strip, mounted **once** in `MainScreen` above the `IndexedStack`
(`Scaffold(body: Column[AppBreadcrumbBar, Expanded(IndexedStack)])`). This is
deliberately *not* per-screen app-bar surgery: one implementation, all six
modes get it for free, and no boot-screen tooltips move (the integration test
asserts those).

Contents, left → right (static layout, spelled-out labels, per UI
preferences):

- A back arrow (enabled when depth > 1) → `history.back()`.
- The crumb chips with `▸` separators; last crumb is the current location and
  is not clickable. Adapt `NavigationTrail`'s rendering; its board-position
  scope stays where it is (the repertoire screen's internal stack is a
  different concern and keeps working unchanged).
- The existing `AppModeMenuButton` stays in each screen's app bar as the mode
  *switcher*; its `onSelected` becomes `history.resetTo(mode)`.

Fidelity caveat (accepted for v1): popping a crumb re-delivers the original
handoff, so the screen restores to the handoff's state, not to the exact
scroll/move position you left. Entries can later snapshot extra state (a FEN,
a game index) — `NavigationEntry` already models a `fen` field — but re-fire
is good enough to ship.

### Handoff extension

`OpenPgnViewer` grows two fields (additive, existing callers unaffected):

```dart
OpenPgnViewer({required this.pgnPath, this.sliceFen,
               this.gameId,        // GameRecord.dedupKey — survives re-sorting
               this.autoAnalyze = false});
```

The viewer's consumer (`_openFileWithPositionSlice`) resolves `gameId` →
`goToGame(index)` after load, and if `autoAnalyze` and `tryLoadFromPgn` found
no cached evals, starts `analyzeGame()` (behind the existing
`EngineGate.ensureAvailable`).

---

## Part 2 — The "Games" home page

### New mode

`AppMode.games`, first in the enum's display order; a new
`lib/features/games/` feature dir (`controllers/ models/ services/ widgets/`).
Becomes the **default landing mode** (change `AppState._currentMode` default).
⚠️ The integration boot test asserts tactics boot-screen tooltips — update
`integration_test/app_test.dart` in the same commit, or (safer first step)
land the mode behind the menu first and flip the default in a follow-up
commit that updates the test.

### Data

`RecentGamesController` (`SafeChangeNotifier` — it fetches in the
background):

- Sources: the default usernames from Settings → Accounts
  (`AppState.lichessUsername` / `chesscomUsername`), both platforms, merged
  and sorted by date desc. Empty-state card prompts to set usernames
  (mirrors existing empty-state conventions).
- Fetch through `GamesLibraryService`. Two fixes ride along:
  1. **Its default Lichess fetcher must route through `LichessApiClient`**
     (today it uses bare `http.get`, bypassing rate limiting/auth).
  2. **Refresh must merge, not overwrite.** Today a TTL refresh rewrites the
     cache file wholesale — which would destroy `[%eval]` review annotations
     the viewer persists into it. Change: parse the fresh download, dedupe by
     `GameRecord.dedupKey` against the existing file, append only new games,
     keep existing (possibly annotated) game text verbatim. This also gives
     incremental sync for free.
- Row view-model `RecentGame`: wraps `GameRecord` + derived fields — my
  color, opponent + ratings (headers), result from my perspective, `"3 + 2"`
  display (TimeControl `180+2`), move count (count SAN tokens at parse),
  game URL, review status (accuracy pair if analyzed, else "Review"), and
  the deviation summary from Part 3.

### UI

Static table-shaped list (no reflow), columns exactly as the chess.com
example: time control · players with ratings (usernames always visible) ·
result · accuracy (blank until reviewed, like chess.com) · Review button ·
moves · date. Platform icon instead of avatars (no avatar fetching in v1).
Filters (speed, platform, count) behind the gear dialog. Row click and the
Review button both do:

```dart
history.push('Game ${white} vs ${black}',
    OpenPgnViewer(pgnPath: cacheFile, gameId: record.dedupKey, autoAnalyze: true));
```

Because the backing file is the games-library cache file, the analysis pass
persists `[%eval]` into it, and reopening the game restores instantly via the
existing cached-restore path.

### Accuracy

Compute locally, uniformly for both platforms (chess.com's `accuracies` JSON
exists only for games reviewed on chess.com; don't depend on it):

- In `GameAnalysisController`, after the pass, compute per-side accuracy from
  the already-available per-move win chances using the published Lichess
  formula (per-move `103.1668·e^(−0.04354·Δwin%) − 3.1669`, combined per
  side); expose alongside ACPL and inject as headers
  (`[WhiteAccuracy "89.4"]`/`[BlackAccuracy "78.4"]`) through the same
  `persistMoveComments` write.
- The games list reads those headers — no sidecar store needed, and the
  numbers survive restarts because they live in the PGN.
- While at it, note (not required for this feature): the tactics-mining copy
  of the win%-classification curve duplicates this logic inline; a later
  cleanup can converge both on `ease_utils.dart`.

---

## Part 3 — Repertoire deviation per game

### Designating "my" repertoires

New Settings section **My Repertoires**: pick repertoire folder(s) (from the
existing repertoire list UI) for **White** and for **Black**. Persist the
folder paths (SharedPreferences JSON). Multiple folders per color allowed;
all chapters of all designated folders form that color's *book*. Sanity
check each chapter's `// Color:` header and surface mismatches instead of
silently including them.

### `GameDeviationService` (new, `lib/features/games/services/`)

The missing per-game walker — pure and unit-testable:

- Build (and cache) a **union `MoveTree` per color** from the designated
  files, the same way `RepertoireController.buildRepertoireMoveTree()` unions
  `RepertoireLine.moves` — but as a standalone function taking file paths, so
  it runs outside the builder screen. Invalidate by file mtimes.
- Walk one game's SAN mainline from the start against the union tree
  (choosing the tree by my color in that game). At each ply, `findChild(san)`
  with `+`/`#` suffix normalization (reuse the `_stripSanSuffix` approach
  from `games_draft.dart` — `RepertoireDiff`'s strict matching is a known
  gap). First miss ends the walk:

```dart
class DeviationReport {
  final int plyIndex;            // 0-based ply of the first off-book move
  final bool byMe;               // my move left book vs opponent's did
  final String playedSan;
  final List<String> expectedSans; // repertoire children at that node
  final List<String> pathSans;   // game SANs up to the deviation
  final String repertoirePath;   // which designated folder matched deepest
}
// null report ⇒ never in book (first move off-book) or fully in book
```

- O(game length) tree walk, no engine, no network — cheap enough to run for
  every visible row when the games list loads.
- Transposition tolerance (FEN-set matching via `collectFenPrefixes`) is a
  deliberate v2 item; SAN-prefix matches how `RepertoireDiff` and the merge
  planner already define "in repertoire", so v1 stays consistent with them.

### Surfacing it

- **Games list row**: a small chip — "Left prep at move 9 (you)" / "Opponent
  left prep at move 6" / "In book" / nothing when no repertoire is designated
  for that color.
- **PGN viewer**: when the loaded game has a report, mark the deviation ply
  in the movetext (annotation glyph on that move) and show a one-line banner
  in the Analysis tab: played vs expected, plus **"Open in repertoire"** →

```dart
history.push('Repertoire "${name}"',
    OpenBuilder(repertoirePath: report.repertoirePath,
                moveSequence: report.pathSans));
```

  — producing exactly the target trail:
  `Games ▸ Game BigMan vs MaouTanner ▸ Repertoire "Dynamic 1.d4"`, with each
  crumb clickable back.

The aggregate view ("across all my games, where do I keep drifting?") is
**not** rebuilt here — that is the existing Draft flow
(`GAMES_DRIVEN_REPERTOIRE.md`); this feature is its per-game complement, and
both read the same games-library cache.

---

## Sequencing

1. **`AppHistory` + breadcrumb bar** — additive; migrate the 12 handoff
   producers + `AppModeMenuButton`; unit tests on the stack semantics
   (reset/push/popTo/re-delivery, cap, generation lock). Ships value alone:
   every existing cross-screen jump becomes back-navigable.
2. **Games library hardening** — merge-on-refresh (annotation-safe),
   Lichess fetcher through `LichessApiClient`.
3. **Games home mode** — `RecentGamesController` + list UI + extended
   `OpenPgnViewer` (gameId, autoAnalyze). Land behind the mode menu first;
   flip the default landing mode + integration test in its own commit.
4. **Accuracy** — compute + persist headers in `GameAnalysisController`,
   display in list and in the existing `GameAnalysisSummary` cards.
5. **Deviation** — My Repertoires settings, `GameDeviationService` + tests,
   row chips, viewer banner + repertoire deep link.
6. **Later**: transposition-tolerant matching, crumb state snapshots
   (restore exact move/scroll), chess.com `accuracies` import as a
   pre-filled fallback, avatars, mouse back-button / Alt+Left.

## Open questions

- Default landing mode: Games vs keeping Tactics (design assumes Games).
- Accuracy formula fidelity: plain Lichess per-move formula + harmonic mean
  vs their volatility-weighted variant (v1: simple combination, labeled).
- Deviation chip threshold: suppress "left prep" reports past a ply cap
  (e.g. beyond move 20 it's noise)?
- How many games the home fetches per platform by default (v1: reuse
  `GameSelection` defaults, gear-configurable).
