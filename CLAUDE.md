# Chess Auto Prep — agent instructions

Flutter desktop app (Linux/Windows/macOS) for chess prep: tactics from your own
games, repertoire building/training, player analysis, studies.

## Start here

This checkout is shared by several agent sessions at once and is routinely
mid-refactor. Before you trust it, check it:

```
scripts/doctor.sh          # toolchain, fetched assets, the lock, the driver,
                           # the tree, and whether the agent contract is tracked
```

Four slash commands wrap the workflows below, so you do not have to
reconstruct them from this file each session:

| Command | What it does |
|---|---|
| `/doctor` | the health check above, plus what to do about each finding |
| `/gate` | the pre-commit gates through the shared Flutter lock |
| `/drive` | build, launch and drive the real app; screenshot what you changed |
| `/run-skill-generator` | author or improve a skill, held to this repo's rules |

Three skills carry the detail the commands point at, and trigger on their own
when a task matches their description:

| Skill | Owns |
|---|---|
| `run-chess-auto-prep` | the app driver (`driver.py`): build, launch, tap, type, screenshot |
| `chess-prep-mcp` | the chess-prep MCP server: expectimax builds, tournaments, master and own games, PGN trees, rosters; `mcp_tools.py` to call it from a shell |
| `bughouse-mcp` | the bughouse MCP server: Hivemind on two boards, joint actions, candidate ranking, and why its score is not pawns |

They live in `.claude/commands/` and `.claude/skills/`. Those directories,
`.claude/settings.json`, `.mcp.json` and `scripts/hooks/` are **tracked in git
on purpose**: they are the whole reason a fresh clone behaves. `doctor.sh`
fails if any of them drifts back to untracked, and checks every skill's
frontmatter.

## Keeping CI green (non-negotiable)

CI (`.github/workflows/ci.yml`) runs format check → analyze → coverage-enforced
Flutter tests → offline Python tool tests, plus a headless integration test.
It runs for pull requests and pushes to `main`, and the release workflow calls
it before any platform build. Local checks remain mandatory before **every**
commit; run them through the one script that serialises Flutter work:

```
scripts/ci.sh              # format + analyze + coverage tests + tools + lint
scripts/ci.sh analyze      # any subset: format analyze test tools lint integration
scripts/ci.sh status       # who holds the lock, what is cached for this tree
scripts/ci.sh unlock       # clear a lock left behind by a job that is gone
```

What it does, and why it exists:

- **One heavy Flutter job at a time, machine-wide.** Several agents used to
  launch `flutter test` / `flutter analyze` at once and crash the machine.
  `ci.sh` takes a `flock` (`/tmp/chess-auto-prep-flutter.lock`, shared with
  the app driver below), so parallel callers queue instead of piling up.
- **The lock dies with the job that took it.** A flock lives on the open file
  description, which every forked child shares — so on 2026-09-04 a killed
  `flutter test` left ten `flutter_tester` isolates behind, each still holding
  the inherited fd, and the lock stayed taken for 45 minutes by a process that
  no longer existed. Every agent on the machine queued behind it. Three things
  keep that shut, and if you touch the locking code, keep all three:
  `capped()` runs every heavy command with `9>&-` so nothing but `ci.sh`
  itself ever holds the fd; `sweep_stale_scopes` stops any `chess-prep-ci-*`
  cgroup whose owning pid is gone, on the way in, so even a SIGKILLed run
  (which fires no trap) is tidied by whoever comes next; and `doctor.sh`
  reports a lock whose recorded holder is dead as a **blocking** problem
  rather than an ordinary busy lock, pointing at `scripts/ci.sh unlock`.
  `driver.py` shares the lock and was never affected — Python has opened
  descriptors non-inheritable by default since PEP 446. Do not "fix" it with
  `os.set_inheritable()`.
- **One runaway cannot take the machine with it.** The lock stops *many* heavy
  jobs at once; it does nothing about *one* job going runaway, which is what
  has actually OOM-killed this machine. Two layers now:
  `ci.sh` runs every heavy command — including `ci.sh with -- …` — inside its
  own transient cgroup capped at `CHESS_PREP_MEM_MAX` (default 8G, `0` to opt
  out, swap denied); and `scripts/oom_containment.sh` caps the *desktop app
  scopes* your session actually lives in (10G each, 24G for all of them), so a
  script you write and background yourself is bounded too. Those numbers are
  measured, not guessed — a VS Code window running six agent sessions holds
  3.7G of real memory, and the caps are ~2-3x that; `oom_containment.sh`
  documents the measurements. If a step dies with rc=137 and no test failure it
  hit a ceiling: find the leak, don't just raise the cap.

  The second layer exists because of what happened on 2026-09-04, and the
  lesson is not the one it looks like. A mutation harness set
  `_COLOR_SEARCH_WINDOW = 4` to `10**9`; the *test file imports that constant*
  and sizes a list with it (`range(_COLOR_SEARCH_WINDOW)`), so the child asked
  for a billion objects. Two rules fall out:

  - **A mutation harness must assume any mutant can explode.** Not just loop
    forever or print forever — *allocate* forever, in the test process, when a
    test is coupled to a constant in the module under mutation. That coupling
    is good test design; it is also what makes it dangerous to mutate.
  - **`OOMPolicy=stop` is the real blast radius.** The kernel killed exactly
    one process; systemd then tore down the whole scope around it and seven
    unrelated agent sessions died. `scripts/doctor.sh` checks this is fixed.

  The caps hold because cgroup membership is inherited on fork — `setsid`,
  `nohup`, `disown` and a background `&` all stay inside them, and there is no
  step to remember. They are **not** tamper-proof: everything under
  `user@.service` is user-owned, so an agent can raise its own limit if it
  decides to. Don't. If a cap is genuinely too low, say so and raise it
  deliberately via `CHESS_PREP_*_MAX`, so the new number is measured and
  written down rather than silently lifted.
- **Identical requests share one run.** A passing `analyze`/`test` result is
  cached under a hash of HEAD + your diff + untracked source files; a second
  caller on the same tree replays the log instead of re-running. Any edit
  invalidates it. Failures are never cached. `--fresh` bypasses the cache.
- **Warnings are fatal**, as in CI: the `analyze` step fails on any
  `error •` or `warning •` line even when Flutter's exit code is 0.
- **`format` writes**, it does not just check; `lint` runs the layering and
  font-size greps from this file.
- `scripts/ci.sh with -- <command…>` runs any other heavy command (a release
  build, a one-off `flutter drive`) under the same lock, in your cwd.

A `PreToolUse` hook (`.claude/settings.json` → `scripts/hooks/flutter_gate.sh`)
denies raw `flutter test|analyze|run|build|drive`, `dart test`, `build_runner`
and `xvfb-run` from agent shells, pointing at `ci.sh` and the driver. It is
not a suggestion: go through the gate. Everything else passes untouched —
`flutter pub get`, `dart format`, `dart run tools/run_engine_tournament.dart`,
the Python tests under `tools/mcp/` — because none of those is a Flutter
build. The hook and this paragraph are kept in step; if you change one,
change the other.

CI pins Flutter (see `flutter-version` in `ci.yml`) so formatter output can't
drift between stable releases. If you bump the pin, re-run `dart format` in the
same commit. `scripts/doctor.sh` compares the pin against the local SDK and
warns when they differ — a mismatch means local `format` can be green while the
tag build fails.

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
  when growing an existing one (`audit`, `browse`, `coverage`, `databases`,
  `engine_tournament`, `eval_tree`, `games`, `holes`, `master_games`,
  `planner`, `repertoire`, `tactics`, `traps`, `tricks`).
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
| `tools/mcp/chess_prep/` | The chess-prep **MCP server** (`.mcp.json`): 44 tools at the time of writing (`mcp_tools.py check` prints the live count) for expectimax builds, engine tournaments, the master-games and own-games databases, PGN trees, ChessDB and roster prep. Appears in a session as `mcp__chess-prep__*`; load one with `ToolSearch "select:mcp__chess-prep__<tool>"`. | the `chess-prep-mcp` skill; `python3 .claude/skills/chess-prep-mcp/mcp_tools.py list\|describe\|call` from a shell; `python3 tools/mcp/test_*.py` |
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

- `scripts/doctor.sh` first — it is read-only, takes no lock, and catches the
  things that otherwise waste a whole build (missing fetched assets, a held
  lock, a Flutter/CI version mismatch, a tree someone else has half-refactored).
- `scripts/ci.sh` (analyze + coverage + Flutter/tool tests) plus code reading is the baseline. For
  anything with a visible surface, **also run the app and look at it**: the
  `/run-chess-auto-prep` skill (`.claude/skills/run-chess-auto-prep/`) builds
  and launches the real desktop app, then drives it from the shell —
  `driver.py dump | tap | type | scroll | ss` — and saves screenshots you can
  open. Its build phase takes the same lock as `ci.sh`.
- The working tree is shared by several agents at once, and is routinely
  mid-refactor. If it does not compile, do not "fix" someone else's half-done
  change: launch from a clean snapshot instead (`driver.py start --worktree`
  builds HEAD in `/tmp/chess-auto-prep-worktree`), or point `--src` at your
  own worktree.
- The app window opens on the real display (no Xvfb here). The driver injects
  pointer events straight into Flutter, so it never needs the window focused,
  and it drives the app against the developer's **real** data: don't press
  anything that downloads games or starts an engine run unless that is what
  you are testing.
- Local Flutter lives at `~/sdk/flutter/bin/flutter` on the primary dev machine;
  plain `flutter` may not be on PATH. `ci.sh` and the driver find it themselves.
