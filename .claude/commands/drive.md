---
description: Build, launch and drive the Chess Auto Prep desktop app to see a change working — tap, type, scroll, screenshot — instead of guessing from the code.
argument-hint: [what to look at, e.g. "the tactics home cards"]
---

Look at the real app: $ARGUMENTS

Use the `run-chess-auto-prep` skill — it owns the driver. The short version:

```
python3 .claude/skills/run-chess-auto-prep/driver.py start --worktree
python3 .claude/skills/run-chess-auto-prep/driver.py dump
python3 .claude/skills/run-chess-auto-prep/driver.py tap text="…"
python3 .claude/skills/run-chess-auto-prep/driver.py ss before-fix
```

Read `.claude/skills/run-chess-auto-prep/SKILL.md` for the full command set
(`type`, `scroll`, `settle`, `reload`, `restart`, `log`, `status`, `stop`).

Three things that will burn you if you skip them:

- **`--worktree` builds HEAD in a snapshot.** The shared tree is routinely
  mid-refactor by another session; if it does not compile, that is not your
  bug to fix. Drop `--worktree` only when you specifically need your own
  uncommitted changes on screen.
- **This drives the developer's real data.** Do not press anything that
  downloads games or starts an engine run unless that is exactly what you are
  testing.
- **The app can vanish under you** — another agent runs `stop`, or it crashes.
  The driver now says so plainly instead of throwing; when it does, check
  `driver.py log n=40` before re-launching.

Finish by taking a screenshot and actually looking at it. Report what you saw,
not what you expect the code to do — and if the screenshot does not show what
you claimed, say that.
