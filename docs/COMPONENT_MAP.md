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
  lesson owners. Training records remain under Documents.
- Viewer owns collections, selection/filter/sort and held edits; analysis tabs
  preserve their source draft. Export uses the exclusive PGN exporter.
- Study uses the same document session for chapters, tags, starts, cleanup,
  quiz markers, import/export and retained retry commands.
- Tactics mines downloaded games into `tactics_sets/Default.pgn`, trains puzzles
  on the shared board and can inspect the source game. Alternative answers use
  a supervised finite engine job; unavailable checks do not invent grades.
- Players/prep owns identities, groups, downloads, findings, prepared flags and
  linked prep studies. Cross-mode wiring lives in `app/`, not panel imports.
- Databases browses/imports/downloads master games and reports storage usage.
  Cleanup is limited to explicitly selected derived data.
- Generation owns search trees and draft publication; Replies/gaps and Audit
  use the current workspace and chapter revision.
- Engine tournaments use the shared supervisor, retryable checkpoints, saved
  history, ratings/crosstables and viewer handoff. Bughouse keeps its own two-board
  screen, Hivemind analysis, archive/book reads and saved matches.
- Settings includes accounts, engine/training controls, diagnostics, shortcuts,
  licenses and verified update downloads/install-on-close.
  The engine pane's gear swaps its lines in place for Lines, CPU cores and
  Memory sliders; both views write the same settings, which the workspace
  wiring applies to the running engine.

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
