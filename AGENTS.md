# Chess Auto Prep

Flutter desktop app for Linux, Windows and macOS: chess preparation,
repertoires, training, player analysis and studies.

## Local-first workflow

- The user's working checkout on local `main` is where completed changes belong.
  Routine tasks need no PR or separate merge approval. Read
  [Local integration and publishing](docs/agents/git.md) before integrating.
- Edit/test in an isolated task worktree, then automatically integrate into
  local `main` with `python3 scripts/agent_integrate.py` from the task worktree.
  A pushed task branch alone is not completion: report when it is visible on main.
- `origin/backup/local-main` is the automatic development backup.
  `origin/main` is the published version: update it only when the user asks to
  publish/release. Never use a plain `git push` from local main.

## Work safely

- Use one worktree per editing task:
  `python3 scripts/agent_worktree.py <task-name>`.
  It branches from current local `main` and pushes the task branch before work.
- Prepare an existing agent-created worktree with
  `python3 scripts/agent_worktree.py --prepare . --assets-from /path/to/main-checkout`.
- Branch-backed worktrees must never live under `/tmp`. Detached `/tmp`
  snapshots are disposable and only for tests, previews or bisects.
- Never reset another checkout, change another agent's unfinished edits, or
  kill its jobs. If the environment is unfamiliar or a command fails, run
  `scripts/doctor.sh --quiet` and address findings relevant to your task.
- Run heavy commands through `scripts/ci.sh` or `scripts/ci.sh with -- COMMAND`.
  If queued, do independent work; use `scripts/ci.sh status` to inspect jobs.
  Do not bypass failed containment or submit duplicate jobs.
- App checks use `python3 scripts/app_driver.py start` with headless display
  and disposable data. Keep fixtures in the profile reported by the driver;
  never use the user's real databases for automatic checks.
  Use `--visible` only for an explicit demo or necessary native desktop check.
  Missing Xvfb: run `scripts/setup_agent_display.sh`, never fall back to visible.

## Verify and hand off

- Choose checks that exercise the change. For code changes, run
  `scripts/ci.sh analyze lint` and relevant tests before committing;
  e.g. `scripts/ci.sh test test/path_test.dart`. Format only changed Dart files.
  For instructions/docs-only changes, run `scripts/ci.sh lint` and check links.
- For visible changes, use the `run-chess-auto-prep` skill and inspect a
  screenshot from the headless app. Stop your preview before testing its tree.
- Full coverage, offline tools and integration checks run on the development
  backup in GitHub CI. Require a passing batch before publishing; a full local
  suite before each commit is not required.
- Before stopping, waiting for later or reporting completion, commit all
  intended files and push. Push checkpoint commits during long tasks.
- Keep useful local commits/checkpoints; do not rewrite shared local main to
  tidy history. Squash the development batch in a separate publication worktree
  when requested. Release/version changes stay a separate commit.
- Before handing off, run `python3 scripts/agent_worktree.py --verify .`.
  It must confirm a clean tree and the exact HEAD on the remote. Report the
  branch, commit SHA, checks (including failures/skips) and branch dependencies.
- Integrate against current local main, preserving its unpublished commits and
  unrelated working edits. Resolve conflicts in your task worktree and retest.
  Never stash/reset someone else's edits or force-push either main or its backup.
  Verify the main backup with `python3 scripts/agent_integrate.py --verify`.
  If integration is blocked by overlapping unfinished edits, identify the paths;
  keep the task backed up and explicitly say it is not yet visible on main.

## Load only guidance relevant to the task

These are conditional reading instructions, not a request to load every link.
Before changing the matching area, read its guide if it is not already loaded.
Paths below are relative to the repository root; they also apply when a task
starts at the root and later edits a subdirectory.

| Task | Guide |
|---|---|
| Dart code (`**/*.dart`) | [Dart conventions](docs/agents/dart.md) |
| Widgets, screens, theme or UI tests | [UI conventions](docs/agents/ui.md) |
| Tools, engines, MCP, packaging or the separate web service | [Tooling map](docs/agents/tooling.md), then only the relevant skill/README |
| Documenting behavior/API/layout changes or changing the backlog | [Documentation](docs/agents/documentation.md) |
| Changing agent rules, skills or their loading | [Rule maintenance](docs/agents/README.md) |

Use `chess-prep-mcp` for chess data, expectimax, tournaments and roster work;
use `bughouse-mcp` for bughouse positions or its MCP server. Their skill
instructions own the commands; do not copy tool catalogs into this file.
