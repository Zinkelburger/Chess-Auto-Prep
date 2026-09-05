# Chess Auto Prep — agent instructions

Flutter desktop app (Linux/Windows/macOS) for chess prep: tactics from your own
games, repertoire building/training, player analysis, studies.

## Local agent workflow

Use one worktree per editing task. Codex, Claude Code and Cursor can create
worktrees themselves; run `python3 scripts/agent_worktree.py --prepare . --assets-from /path/to/main-checkout` inside a new one to fetch dependencies
and link immutable engine assets. Or use `python3 scripts/agent_worktree.py <task-name>` to create and prepare one. Never reset another agent's checkout.

- Start with `scripts/doctor.sh --quiet` when the environment is unfamiliar or
  a command fails. It is diagnostic, not a prerequisite for every action.
- Run focused tests while developing: `scripts/ci.sh test test/path_test.dart`.
  Run `scripts/ci.sh analyze lint` and the tests relevant to your change before
  committing. Formatting may be limited to the Dart files you changed.
- Full coverage, offline tools, and integration checks remain mandatory on PRs
  in GitHub CI. A full local suite before every commit is **not** required.
  `scripts/ci.sh full` is available when a broad local check is useful.
- Heavy commands go through `scripts/ci.sh` or `scripts/ci.sh with -- COMMAND`.
  They share two machine-wide slots, with two CPUs and 8 GiB per job and a
  combined 16 GiB ceiling. Tests default to two workers. One heavy job at a time
  may use a checkout's build files. Editing, reading and lightweight commands
  do not take machine-wide slots.
- App checks are headless and use disposable data by default:
  `python3 scripts/app_driver.py start`, then `dump`, `tap`, `ss`, and `stop`.
  Keep fixture files inside that checkout's profile (the driver status prints
  its path). Do not point automatic checks at the user's real databases.
- Use `start --visible` only when the user asks to see a window or a native
  desktop behavior needs it. Missing Xvfb is an error, never permission to open
  the user's screen. Run `scripts/setup_agent_display.sh` to install it.
- `scripts/ci.sh status` reports active slots. If a job queues, do independent
  work instead of submitting duplicates. Old checkouts' exclusive Flutter
  locks are respected until their existing jobs finish. Never kill another
  agent's job to free a slot; closing your launcher cancels its own children.

The runner enforces limits and cleanup; keep those mechanics out of prompts.
If systemd cannot provide containment, the job fails without running uncapped.
The app's one-thread Stockfish default is a preference, not a resource limit.

## Committing

One task, one commit. Everything a session produces for a single piece of
work — the change, its tests, the docs it forces — lands as one commit, never
as a trail of "wip", "fix test", "address feedback". A mammoth push is still
one commit if it is one piece of work; the size of the diff is not a reason to
split it.

Split only when the parts are genuinely independent and you would want to
revert one without the other. A release/version bump stays its own commit.

If a branch already carries intermediate commits, squash before handing the
work back or opening a PR. Interactive rebase is not available here, so:

```
git reset --soft $(git merge-base HEAD main) && git commit
```

Or merge with `--squash`, or `git merge-base` against whatever the branch
forked from. Never rewrite history that is already pushed, already on `main`,
or in another agent's checkout — squash your own branch before it leaves,
not after.

## Conventions that CI enforces indirectly

- **`SafeChangeNotifier`** (`lib/utils/safe_change_notifier.dart`): any
  `ChangeNotifier` service that starts fire-and-forget async work (file loads,
  network fetches) must mix it in, or the integration boot test fails with
  "used after being disposed" teardown races. Already applied to `AppState`,
  `StudyController`, `TacticsDatabase`, `TacticsImportCoordinator`,
  `TacticsSessionController` — follow suit for new notifier services.
- **`flutter test` blocks real HTTP.** The test binding answers every socket
  with an empty 400, so a unit test that "downloads" silently gets nothing.
  Stub the client in unit tests; only the benchmarks under `test/benchmark/`
  and the Lichess controller test clear `HttpOverrides.global` deliberately.
- **Integration tests** (`integration_test/app_test.dart`) assert real UI text
  and tooltips on the boot screen (e.g. `find.byTooltip('Engine settings…')`).
  If you rename or move boot-screen controls, update the test in the same
  commit.

## Where code goes

Two layouts coexist. Both are intentional; the rule for choosing is:

- **`lib/features/<name>/`** — everything owned by one feature, in
  `controllers/ models/ services/ widgets/`. Use this for new features and
  when growing an existing one (`audit`, `browse`, `coverage`, `engine_tournament`,
  `eval_tree`, `games`, `holes`, `master_games`, `planner`, `repertoire`,
  `tactics`, `traps`, `tricks`).
- **`lib/core/ models/ services/ widgets/`** — genuinely cross-cutting code
  used by three or more features or screens. `TrapLineInfo` lives in
  `lib/models/` for exactly this reason: 27 files across four layers use it,
  so it is a shared domain model rather than a `traps` internal. The mirror
  case: `TacticsSetMetadata` stays in `lib/models/` even though everything
  else tactical moved into `features/tactics/`, because it is what
  `StorageService.listTacticsSets()` returns — the storage layer's own type,
  sitting beside `RepertoireMetadata` for the same reason.

A feature's *pipeline* code can stay in `lib/services/` when it belongs to
that pipeline rather than to the feature UI — `services/generation/
trap_extractor.dart` produces traps during a build; `features/traps/` consumes
them. That boundary is deliberate.

Never re-export a type from a second path to make both layouts work. Two
`trap_line_info.dart` files (one a shim) meant half the codebase imported each
one and neither was obviously canonical. Pick the home, move the file, fix the
imports.

**Layering, enforced by `scripts/ci.sh lint`:** `core/`, `models/`, `services/`
and `utils/` must not import from `widgets/` or `screens/`, and neither may a
feature's own `controllers/`, `services/` or `models/`. Both greps live in the
`lint)` branch of `ci.sh` — run it, do not retype them here, and add any new
allowlist entry there rather than in prose:

```
scripts/ci.sh lint     # layering + the 12px type floor; cheap, never queues
```

The allowlist is deliberately one line long
(`features/repertoire/controllers/build_launcher.dart`, which imports two form
widgets). Shrink it; do not grow it.

## Tooling beyond `lib/`

Several programs live in this repo that the app does not ship. Know which
one you are in before editing:

| Path | What | Run it via |
|---|---|---|
| `tools/mcp/chess_prep/` | The chess-prep **MCP server** (`.mcp.json`): 44 tools at the time of writing (`mcp_tools.py check` prints the live count) for expectimax builds, engine tournaments, the master-games and own-games databases, PGN trees, ChessDB and roster prep. Appears in a session as `mcp__chess-prep__*`; load one with `ToolSearch "select:mcp__chess-prep__<tool>"`. | the `chess-prep-mcp` skill; `python3 .Codex/skills/chess-prep-mcp/mcp_tools.py list\|describe\|call` from a shell; `python3 tools/mcp/test_*.py` |
| `tools/mcp/bughouse/` | The bughouse **MCP server** (`.mcp.json`): six tools that put Hivemind's two-board search in reach of an agent — `position`, `legal_moves`, `analyse`, `compare`, `playout`, `status`. Appears as `mcp__bughouse__*`. Shares the app's engine bundle read-only and its transport with chess-prep. | the `bughouse-mcp` skill; `mcp_tools.py --server bughouse …`; `python3 tools/mcp/test_bughouse.py [--engine]` |
| `tools/mcp/mcp_stdio.py` | The JSON-RPC-over-stdio transport both servers use. Zero dependencies, because an MCP client starts a server from a bare `command`/`args`. | imported by each server's `server.py` |
| `tools/fetch_bughouse.py` | Downloads the Hivemind CPU build (engine + ONNX Runtime + FP32 network) into `assets/bughouse/` (gitignored), exactly the way `fetch_assets.py` fetches Stockfish — same `--only`/`--check`/`--force`, pinned in `tools/bughouse.lock.json`. `--hivemind <checkout>` packs a local engine build instead. The app **hides** Bughouse Lab when these are absent, so a checkout without them is fine. | `python3 tools/fetch_bughouse.py` |
| `tools/test_bughouse_engine.py` | Whether the fetched bughouse engine can actually **run** where we ship it. `deps` reads each binary's own import table and insists every dependency is either part of the OS or shipped beside the engine — the check that catches a Windows bundle needing a DLL nobody ships, which is invisible on a machine that happens to have it. `run` extracts the way `BughouseBundle` does, loads the network and searches. `.github/workflows/bughouse.yml` runs both on Linux and Windows; `release.yml` gates every release on them. | `python3 tools/test_bughouse_engine.py [deps [--all] \| run]` |
| `tools/diagnose_bughouse_windows.ps1` | Why the bughouse engine will not start on **someone else's** Windows machine. Self-contained (no checkout, no Python): it reads the extracted engine's sizes and PE headers, checks every shipped file's SHA-256 against the bytes the release actually published (the one failure the sizes cannot see, and the one the app cannot repair on its own), walks the loader's own search order for every library the engine imports, names any that resolve to a 32-bit or truncated file, reports any per-image Exploit Protection mitigation, and then starts the engine for real. This is what to send a user who reports "could not start". | `powershell -ExecutionPolicy Bypass -File diagnose_bughouse_windows.ps1` on the failing machine |
| `tools/bughouse_db/` | The FICS **bughouse archive** as an opening book: `fetch` the yearly BPGN dumps from bughouse-db.org (2.1 GB, kept compressed), `index` them into a `bughouse_book.db` sqlite book, `explore` a two-board position in it, `status` for what is on disk. Both live under `~/.local/share/chess-prep/bughouse-db/`, never in the repo or in `assets/`. Offline tooling — nothing in `lib/` opens that book yet. | `python3 -m bughouse_db <command>` from `tools/`; `python3 tools/test_bughouse_db.py` |
| `tools/fetch_assets.py` | Downloads the host Stockfish into `assets/executables/` (gitignored). Required before any build. | `python3 tools/fetch_assets.py` (`--check` to verify) |
| `tools/run_engine_tournament.dart` | Headless engine-vs-engine matches; same directory layout as the app and the MCP tools (`docs/ENGINE_TOURNAMENT.md`) | `dart run tools/run_engine_tournament.dart …` |
| `tools/bench/`, `tools/dart_api_test/`, `tools/experiments/` | Benchmarks and API harnesses; nothing here is imported by `lib/` | `dart run`, or `scripts/ci.sh with --` when it is heavy |
| `tree_builder/` | Standalone C prototype of expectimax and the cdbdirect (local ChessDB) native build; the Dart port in `lib/services/generation/` is canonical | `make` inside it; see its README |
| `python/twic-position-finder/` | A separate web service (`api.chessautoprep.com`), deployed on its own | its own README |
| `packaging/`, `install_linux_desktop.sh` | Installers (.deb, flatpak, Windows) built by the release workflow from a release bundle | release CI |

The MCP server and the app share data through files only: the server reads
the app's `master_games.db` / `app_games.db` read-only, and writes its own
runs under `~/Documents` and `~/.local/share/chess-prep/`. `expectimax_run`,
`tournament_run`, `pgn_eval` and `pgn_audit` start Stockfish for minutes and
are **not** behind the Flutter lock, so start one only when that is the task.

## Decomposition

`part`/`part of` splits a file, not a class — every part still sees the host's
private state, so a god class spread over parts is still a god class. Use parts
to separate *types*, never to shrink one class. When a class is too big, extract
a real collaborator with its own constructor and tests (see
`services/training/chapter_scope.dart` and `review_progress_store.dart`, both
carved out of `TrainingSessionController`).

Collaborators that read owner state which the owner *reassigns* (a settings
reload, a new file) should take supplier callbacks (`TrainingSettings Function()`)
rather than cached references, so the two cannot desync. But pass a value
explicitly when the caller deliberately snapshotted it across an `await` —
`ChapterScope.resolveLayout` takes `isStudy` for that reason.

The same pattern has since been applied to the other three big controllers:
`services/generation/course/course_builder.dart` (the enrichment passes and
course composition, out of `GenerationSessionController`),
`services/training/training_run.dart` (what one sitting covers and what comes
next, out of `TrainingSessionController`), and
`services/repertoire_pgn_text.dart` (editing a repertoire's PGN as text, out
of `RepertoireService`). Each has its own tests; none needs a notifier, a
board or a file.

## Reach for these before writing a fifth copy

Duplication in this repo has a pattern: the same idea gets re-typed per screen
and the copies drift until two of them disagree and one is wrong. Before
hand-rolling any of the following, check the shared one:

| Need | Use |
|---|---|
| "3h ago" / "in 5d" / an elapsed or ETA duration | `utils/time_format.dart` |
| A centipawn or mate score as text | `formatEvalDisplay` / `formatPackedEval` (`utils/chess_utils.dart`) |
| Numbered movetext | `buildNumberedMovetext` (`utils/movetext_builder.dart`) |
| A NAG's symbol or colour | `utils/pgn_nags.dart` |
| A labelled number, inline or stacked | `InlineStat` / `StackedStat` (`widgets/common/stat_display.dart`) |
| "Are you sure?" | `confirmAction` (`widgets/common/confirm_dialog.dart`) |
| "Name this thing", with validation | `showNameEntryDialog` (`widgets/common/name_entry_dialog.dart`) |
| A findings report with filters, a cap and dismissal | `HuntReportPanel` (`features/audit/widgets/hunt_report_panel.dart`) |
| A threshold field, a "more" disclosure, a visible-cap editor | `features/audit/widgets/hunt_controls.dart` |
| Cooperative pause/cancel in a long service loop | `RunControl` (`services/run_control.dart`) |
| Saving a hunt report beside a player's games | `HuntReportStore` (`features/audit/services/hunt_report_store.dart`) |

Type is the same rule: `AppTextStyles.caption` and `AppTextStyles.monoFamily`
exist so `TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted)` and
`fontFamily: 'SourceCodePro'` never have to be typed again. They were, 166 and
87 times respectively, before a pass put them back.

A dialog that owns a `TextEditingController` must be a `StatefulWidget` that
disposes it, not a function that disposes after `await showDialog(...)`: that
returns while the route is still animating out and the field is still mounted,
and the framework asserts.

## Type and colour

Fonts are bundled (`assets/fonts`, declared in `pubspec.yaml`): **Inter** for UI
text, set once on `ThemeData.fontFamily`, and **Source Code Pro** for moves,
FENs and evals (`AppTextStyles.monoFamily`). Never write `fontFamily:
'monospace'` — it resolves differently on every OS.

Five text roles, in `lib/theme/app_text_styles.dart`: title 18 · body 14 ·
secondary 13 · small 12 · mono 13. **12px is the floor** for anything
readable; hierarchy above it comes from weight and from two inks
(`AppColors.ink`, `AppColors.onSurfaceMuted`), not from smaller sizes or a
third grey. Check before committing:

```
grep -rnE "fontSize: (9|10|10\.5|11|11\.5)[,)]" lib
```

should print nothing (board coordinates excepted).

## Verifying changes

Choose checks that exercise the behavior you changed. Use the bounded runner
for builds and tests, and inspect a screenshot from the headless app for visible
changes. Reserve real-desktop checks for native integration or explicit demos.
Report which checks passed, failed, or were not run; keep unrelated failures
separate from regressions caused by your change. Do not repair another agent's
half-finished edits to make your checkout compile; use your own worktree.
