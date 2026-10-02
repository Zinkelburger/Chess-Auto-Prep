# Component map

V2 is the sole application as of 2026-09-30. Production code lives directly in
`lib/`, tests in `test/`, and `lib/main.dart` is the entry point for local and
release builds. V1 source and its old layering/debt ledgers have been removed.
The owner's switch-over decision explicitly excludes legacy/backward-compatibility
requirements. Existing user files are neither migrated nor deleted.

Use [architecture contracts](ARCHITECTURE_RENEWAL.md),
[mode specifications](v2/features/README.md), [the backlog](FUTURE_FEATURES.md)
and [tooling map](agents/tooling.md) for details and remaining product scope.

## Entry points and ownership

- [`main.dart`](../lib/main.dart) configures native directories, logging,
  bundled licenses, the optional agent driver and packaged-app self-tests.
- [`app/app.dart`](../lib/app/app.dart) owns the Flutter app lifetime.
  [`app/environment.dart`](../lib/app/environment.dart) wires filesystem,
  engine and network boundaries. App composition passes concrete owners.
- [`app/workspace_requests.dart`](../lib/app/workspace_requests.dart) coordinates
  opens, mode changes and dirty-draft decisions. [`app/mode.dart`](../lib/app/mode.dart)
  defines every top-level mode.
- [`workspace/document_session.dart`](../lib/workspace/document_session.dart)
  owns the active parsed document, cursor, edits and save state. The shared
  board, move tree, engine and explorer are reused across mode panels.
- [`storage/`](../lib/storage/) owns file/SQLite I/O, settings, revisions,
  backups, recovery and accepted durable writes. UI and pure algorithms do
  not write files directly.

## Directory reference

| Directory | Responsibility |
|---|---|
| [`chess/`](../lib/chess/) | Pure chess/PGN, generation, training, puzzles and tournament algorithms |
| [`diagnostics/`](../lib/diagnostics/) | Logging facade without Flutter dependencies |
| [`engines/`](../lib/engines/) | Engine installation, supervised processes, UCI and finite engine jobs |
| [`net/`](../lib/net/) | Service clients, downloads and login callbacks |
| [`ui/`](../lib/ui/) | Shared controls, theme, shortcuts, notation and selection |
| [`workspace/`](../lib/workspace/) | Shared document, board, analysis, explorer, tabs and tools |
| [`features/`](../lib/features/) | Mode-specific owners and panels; no cross-feature imports |
| [`app/`](../lib/app/) | Composition, cross-mode commands, lifecycle, desktop close and updates |
| [`debug/`](../lib/debug/) | Opt-in headless control and packaged-app checks |

## Modes and shared workflows

All mode names are defined in `app/mode.dart`: Repertoire builder, Books,
PGN Viewer, Repertoire trainer, Study, Tactics, My games, Player analysis,
Players & prep, Databases, Engine tournament and Bughouse lab. The optional
Bughouse mode is offered when its engine assets are present.

- Library and chapter outline share guarded PGN storage; edits, moves, deletes,
  restore and accepted training outcomes use the existing recovery owners.
- Trainer Learn/Review and the shared Train tab use the same scheduling and
  lesson owners. A mode, tab or file detour suspends the current lesson and its
  timers; Resume reclaims the board in the visible Train pane. Back to lines
  ends it explicitly. Accepted ratings finish saving while paused; a changed
  source invalidates the retained lesson. Training records remain under Documents.
- Viewer owns collections, selection/filter/sort and held edits; analysis tabs
  preserve their source draft. Export uses the exclusive PGN exporter. It opens
  on the moves alone (`viewerTabs`), has its own Explorer starting on `This
  file` (`Explorer.independent(starting:)`), and supplies the Filter tab
  (`ViewerFilterPane`) and the followed player's colour choice
  (`PlayerSideChoice`) through `ModeView`.
- Study uses the same document session for chapters, tags, starts, cleanup,
  quiz markers, import/export and retained retry commands.
- Tactics mines downloaded games into `tactics_sets/Default.pgn`, trains puzzles
  on the shared board and can inspect the source game. Text search and filters
  define both the visible puzzle list and Play's counted queue. Alternative answers use
  a supervised finite engine job; unavailable checks do not invent grades.
- Players/prep owns identities, groups, downloads, findings, prepared flags and
  linked prep studies. Failed analysis offers Try again and diagnostic Details;
  an unsuccessful refresh retains the previous corpus and its source revisions.
  `PlayerPosition.addGame` owns result counting for both the corpus and filtered
  statistics; its game and move collections are read-only to consumers. Filtering
  chooses the included games once per statistics calculation before aggregating
  their positions. Cross-mode wiring lives in `app/`, not panel imports.
- Databases browses/imports/downloads master games and reports storage usage.
  Cleanup is limited to explicitly selected derived data.
- Generation owns search trees and draft publication; Replies/gaps and Audit
  use the current workspace and chapter revision. A practical search from the
  board (`workspace/fill_gaps.dart`) builds two trees in one run, the board's
  side and the other; `FillGaps.nodeAtBoard(side:)` reads either, and
  `workspace/search_table.dart` merges them into the Expectimax table's
  White, Black and Engine columns. Saved-tree loading and automatic board-follow
  restarts share one start generation: navigation, a newer accepted start/resume,
  or any stop command invalidates earlier pending starts, including an away-and-back
  navigation. Exact-root results take precedence while preserving newest-first
  order. Engine depths and continuation lines share the same source/depth scope.
- `workspace/index_build.dart` owns each opening-index build. Incremental work
  and isolate messages use the same guarded completion: success, failure and
  cancellation close the timer, receive port and worker. Progress-consumer failures
  reach the result future, and late worker handles are stopped after completion.
- The Repertoire builder starts with two panes: Moves on the left, Expectimax
  on the right (`ActionLayout.startBuilding`), the moves at 45% of the card
  (`builderMovesShare`). Below 1480px (scaled with text size), library and
  chapter navigation share one column with Repertoires/Chapters tabs
  (`NavigationPages`); wider windows show both columns. Both pages retain their
  search and selection while switching or resizing. Hiding the compact column
  hides both pages; Positions selects the list page. Full names remain available
  in tooltips, and outline rows grow with larger text.
  The gap between two panes is a divider: dragged, it sets
  `ActionPaneSplit.share`, which the mode's layout remembers. Rendering clamps
  allocations to the selected tools' widths, including nested splits, without
  overwriting saved proportions. Moves reserves 280px before text scaling when
  space permits; insufficient space divides proportionally. A pane narrower than
  its tab's least width scrolls
  sideways: 320px for most tabs, 180px for Moves, 240px for Expectimax, whose
  bar moves fields down when their text-scaled widths and the gear no longer fit. The builder, the trainer and
  the viewer open a tab picked from `+` under a lone pane
  (`ActionLayout.opensBeside`); the trainer's lesson (`LessonView`) fits half
  the card, its moves taking the height left and scrolling to the latest
  move. As on Lichess, a book button
  leading the nav row shows the main Explorer under the moves
  (`ActionLayout.book`, shut until pressed). Requests for a tab
  (`ActionLayout.reveal`) bring it up in the pane that already has it. The
  Explorer's narrowing folds under a button always labelled Filters
  (`ui/fold_button.dart`); where the databases do not fit side by side they
  become one typeable box (`ChoiceField`).
- Engine tournaments use the shared supervisor, retryable checkpoints, saved
  history, ratings/crosstables and viewer handoff. Bughouse keeps its own two-board
  screen, Hivemind analysis, archive/book reads and saved matches.
- `AccessibleBoard` adds named squares, side-to-move/check announcements,
  orientation-aware arrow navigation, Enter/Space selection and keyboard promotion
  to the shared pointer board. Modified history shortcuts still pass through.
  Submitted notation errors use a stable feedback row below the board controls.
- `LayoutMemory` stores deliberate tool/split/board-width choices in Settings,
  per mode and, for document views, per file. Auxiliary modes keep their layout
  while browsing source games. Writes participate in exit settling. Actions offers
  Reset workspace layout, board width and active pane sizing; tab context menus
  also open with Shift+F10. Mode navigation is grouped and searchable through
  Find a mode and the Actions palette. The reading surface names its Tools menu.
- Engine jobs publish a named kind through `EngineJobs`; the top bar's running
  task button returns to the owning tool without starting a second job. Discard
  of held edits confirms the named document and refuses stale dialog callbacks.
- Settings includes accounts, engine/training controls, diagnostics, shortcuts,
  licenses and verified update downloads/install-on-close.
  The engine pane's gear swaps its lines in place for Lines, CPU cores and
  Memory sliders; both views write the same settings, which the workspace
  wiring applies to the running engine. The Expectimax tab's gear does the
  same for the search (`workspace/search_settings.dart`): its rows and
  Settings ▸ Expectimax write `Settings.expectimax`
  (`chess/generation/expectimax_options.dart`), and every way of starting a
  search reads `FillRequest.of(settings)`. `opponentFor` in
  `workspace/search_opponents.dart` turns the request's reply source into the
  search's opponent: Maia, or a games database (Lichess explorer, local master
  book) with Maia behind it. Each opponent node keeps who answered it
  (`OpponentNode.repliesFrom`, saved as `v2_replies_from`), and the table's
  Played share marks a Maia stand-in `~` with a tooltip naming the source
  and a visible legend explaining the marker.

Unported conveniences remain in the feature specs/backlog; the presence of a
mode is not a claim of every historical v1 control being reproduced.

## Persistence and shutdown

The app uses its existing Documents, Support and cache locations. The document
session owns the draft; storage owns commit/revision checks and compound
operations. Accepted writes survive panel disposal. Close flushes user data
before engine shutdown. Unreadable authoritative recovery data is kept or
quarantined; derived views can be rebuilt. Foreign v1 journals are no longer
processed or used to block current saves, and are left untouched.

Line IDs, serialized records and retained fixtures may still describe older
formats. They are data contracts, not dependencies on deleted source. Current
save/reopen, conflict, process-kill and recovery tests remain.

## Checks and tools

- [`test/`](../test/) mirrors the production areas; `test/support/` supplies
  scripted ports, fixtures and property generators.
- [`integration_test/v2_desktop_test.dart`](../integration_test/v2_desktop_test.dart)
  exercises the actual desktop app. Engine/native checks have separate targets.
- [`scripts/check_v2.py`](../scripts/check_v2.py) retains its filename but now
  enforces the sole app's architecture under `lib/` and `test/`.
- `scripts/ci.sh analyze lint`, `scripts/ci.sh test` and `scripts/ci.sh tools`
  run through bounded jobs. The headless driver defaults to `lib/main.dart`.
- Platform runners, `packages/document_file_io`, engine assets/updaters,
  `tools/mcp/`, `tools/bughouse_db/` and the separate `tree_builder/` prototype
  retain their own responsibilities. See [tooling](agents/tooling.md).
