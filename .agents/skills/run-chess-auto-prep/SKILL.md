---
name: run-chess-auto-prep
description: Build, run, drive and screenshot the Chess Auto Prep Flutter desktop app on Linux from the shell — start the app, tap buttons, type into fields, scroll, take screenshots, hot reload, then stop it. Use it whenever a change has a visible surface, the user asks to run, launch, look at or screenshot the app, or you would otherwise be guessing from the code what the UI does. Also how to run the local CI gates (analyze, test, format, lint) without colliding with other agents.
---

# Run Chess Auto Prep

Chess Auto Prep is a Flutter desktop app (`lib/main.dart`, Linux target). You
drive it with **`.Codex/skills/run-chess-auto-prep/driver.py`**: a stdlib-only
Python daemon that wraps `flutter run --machine` and talks to debug-only
service extensions (`ext.chessprep.*`, `lib/debug/agent_driver.dart`) compiled
in with `--dart-define=AGENT_DRIVER=true`. Paths below are relative to the
repo root. Flutter lives at `~/sdk/flutter/bin/flutter`; the driver and
`scripts/ci.sh` find it themselves (`FLUTTER=…` overrides).

There is no Xvfb on this machine. The app window opens on the real display.
That is fine: the driver injects pointer events straight into the Flutter
binding, so it never needs the window focused, and screenshots are rendered
from the layer tree, not grabbed from the screen.

## The lock (read this first)

Several agents share this machine and this checkout. Every heavy Flutter job
— a build, `flutter test`, `flutter analyze` — goes through one `flock`
(`/tmp/chess-auto-prep-flutter.lock`). `driver.py start` holds it while
building and releases it once the app is up; `scripts/ci.sh` holds it for the
duration of analyze/test. Parallel callers queue; they do not pile up. A
`PreToolUse` hook denies raw `flutter test|analyze|run|build|drive` from agent
shells, so use these two entry points.

```
scripts/ci.sh status        # who holds the lock; what is cached for this tree
```

On Linux, the driver also puts `flutter run`, the app, and every engine it
starts in a dedicated systemd user scope. The driver daemon remains in the
agent's scope so it can report an app-side OOM. The development scope defaults
to `CPUWeight=50`, `MemoryMax=8G`, and no swap: it can still use every idle CPU,
but yields to sibling agents under contention and cannot consume the whole
machine. Set `CHESS_PREP_DRIVER_MEM_MAX=12G` to choose another ceiling, `=0`
for no explicit memory ceiling, or `CHESS_PREP_DRIVER_SCOPE=0` to disable the
scope on a machine where systemd user scopes are unsuitable.

## Run (agent path)

```
python3 .Codex/skills/run-chess-auto-prep/driver.py start --worktree
```

`--worktree` checks out `HEAD` into `/tmp/chess-auto-prep-worktree`, overlays
the driver's two files, and builds there. Use it whenever the shared working
tree does not compile (it is routinely mid-refactor by another agent — that
was the case when this skill was written). Omit it to build the working tree
as-is; `--src DIR` builds any other checkout, e.g. your own worktree.

`start` daemonises, prints `queued` / `building` / `running`, and returns when
the app is up (9 s when the build is cached, about 2 min for a fresh
worktree; it gives up after `CHESS_PREP_BUILD_TIMEOUT`, default 900 s).
Concurrent `start` calls serialize on `start.lock`; once the first app is up,
the others reuse it instead of racing two daemons into the shared state dir.
Then:

```
D=.Codex/skills/run-chess-auto-prep/driver.py
python3 $D ping                       # {"ok": true}
python3 $D dump                       # every visible text / tooltip / key / field, with rects
                                      # (its header line names what owns the keyboard —
                                      #  a `… Focus Scope` there means nothing focusable
                                      #  does, so keys reach no panel handler)
python3 $D dump kinds=tooltip,key     # narrower
python3 $D tap tooltip="Switch mode"  # tap by tooltip, text, key, or x= y=
python3 $D tap key=accounts-change-button
python3 $D type text="driver_test_user" key=lichess-username-field
python3 $D tap text=Cancel
python3 $D scroll text="No book set for this colour" dy=600
python3 $D tap key=study-tactics-button
python3 $D ss tactics-session         # → /tmp/chess-auto-prep-driver/shots/tactics-session.png
python3 $D tap tooltip="End session"
python3 $D reload                     # hot reload after editing Dart
python3 $D restart                    # hot restart (state reset)
python3 $D settle                     # wait for the UI to go idle (mutating calls do this themselves)
python3 $D log n=40                   # tail the app's stdout/stderr + flutter progress
python3 $D status
python3 $D stop
```

`status` includes the transient `resourceScope` name for the current run.

Targets: `text=` / `tooltip=` / `key=` / `field=` match exactly first, then as
a case-insensitive substring; `index=N` picks the Nth match. `tap` also takes
`count=2` (double) and `button=secondary`. `type` takes `submit=true` (fires
the field's done action) and `append=true`; when no target is given it types
into the focused field, else the first visible one. With no `key=`/`field=`
the payload is `text=` and a text target is `text_target=`. Every mutating
call waits for the UI to settle before returning, so `dump` right after `tap`
already shows the result.

Screenshots land in `/tmp/chess-auto-prep-driver/shots/`; open them with the
Read tool. Everything else (app log, state, socket) is in
`/tmp/chess-auto-prep-driver/` (`CHESS_PREP_DRIVER_DIR` overrides).

**One instance per machine.** `start` refuses if a driver is already running;
share it or `stop` it. The app talks to the developer's real data (accounts,
games, engine settings): tapping "Check for new games" downloads games and
runs Stockfish on half the cores for minutes. Don't, unless that is the test.

## Other entry points

- `/drive <what to look at>` is the slash command that wraps this skill; the
  built-in `run` skill defers to it too. There is no other launcher — do not
  write one.
- The chess-prep MCP server (`.Codex/skills/chess-prep-mcp/`) reads the same
  data without a window: master games, the user's games, expectimax runs,
  tournaments. Its `tournament_open` / `open_app` tools open the app on a
  tournament, and if this driver already has an app up that is where the
  request lands.
- `scripts/ci.sh integration` runs `integration_test/app_test.dart` against a
  real window on this display, under the same lock as `start`. It is the boot
  test CI runs headlessly on tags; it asserts real boot-screen text and
  tooltips, so rename a boot-screen control and the test in the same commit.

## Run (human path)

```
~/sdk/flutter/bin/flutter run -d linux
```

opens the window and blocks the terminal with the usual `r`/`R`/`q` keys. No
driver, no extensions. Agents should not use it (the hook blocks it anyway).

## CI gates

```
scripts/ci.sh                 # format + analyze + coverage tests + tools + lint
scripts/ci.sh analyze         # any subset: format analyze test tools lint integration
scripts/ci.sh --fresh test    # ignore the cached pass for this tree
scripts/ci.sh with -- <cmd…>  # run anything else under the lock, in your cwd
```

Passing `analyze`/`test` results are cached per working-tree hash, so a second
agent on the same tree replays the log instead of re-running. Failures are
never cached. `analyze` fails on any `error •`/`warning •` line, as CI does.
`test` enforces the line-coverage floor; `tools` runs every deterministic,
offline Python MCP/database test with leaked-resource warnings made fatal.
`integration` runs `integration_test/app_test.dart` on the Linux device — a
window opens on the display.

## Gotchas

- **`driver.py` edits need `stop` + `start`.** The daemon is a long-lived
  process; the client commands are cheap, but the server code is whatever was
  running when you started it.
- **After `restart`, the first extension call can race** `main()` re-registering
  the extensions ("method not available: ext.chessprep.ping"). The driver
  retries that for up to 10 s; if you go around it, expect it.
- **Never send a `PointerAddedEvent` for a synthetic mouse.** Flutter's
  `MouseTracker` asserts if a device is added twice; the assertion escaped the
  extension and every later call timed out at 30 s. The driver uses a
  dedicated device id (4242) and starts with a hover event instead. Handlers
  are wrapped so a framework assertion now comes back as an error.
- **Mouse drags do not scroll on desktop** (`ScrollBehavior.dragDevices`
  excludes the mouse). `scroll` sends a wheel event (`PointerScrollEvent`).
- **Hidden routes are still in the element tree.** `dump` skips anything under
  `Offstage`/zero opacity, which is how the Navigator hides them; a popup menu
  that is open shows up alongside the page beneath it.
- **A hot `reload` after editing `lib/debug/agent_driver.dart` while running
  from `--worktree`** re-copies that one file into the worktree first
  (nothing else). Other edits belong in whatever tree you built from.
- **Icon glyphs show as ``-style text** in `dump`. Target icon buttons by
  `tooltip=` or `key=`, not by that text.
- **Window size is 1280×720** as launched; rects in `dump` are logical pixels
  in that space, and the PNGs are the same size on this 1× display.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `flutter run exited before the app started — see app.log` | Read `/tmp/chess-auto-prep-driver/app.log`. If it is a Dart compile error in a file you did not touch, another agent is mid-edit: `stop`, then `start --worktree`. |
| `driver not running — driver.py start first` | The daemon socket is gone; `status` shows the last state. Start it. |
| `already running (pid N …)` | Another agent's app. Use it (`dump`), or `stop` it if `status` says it is stale. |
| `no visible key matching "…"` | It is not on screen (dialog not open, scrolled away, or on a hidden route). `dump` to see what is. |
| A call takes 30 s and fails with `TimeoutError` | The extension hung. `log n=40` — a framework assertion trace names the cause. |
| `ci.sh: waiting for the Flutter lock (held by: pid … )` | Normal. Someone else is building/testing; you are queued. |
