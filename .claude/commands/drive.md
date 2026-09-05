---
description: Drive and screenshot the real app on a private headless display.
argument-hint: [what to verify]
---

Use the run-chess-auto-prep skill to verify $ARGUMENTS in the task's worktree.
Run `python3 scripts/app_driver.py start`, use `dump` and the interaction
commands, capture with `ss`, inspect the screenshot, and stop the app.
The default display and data are isolated. Use `--visible` only for a requested
demo or a desktop-specific check. Report what the screenshot actually shows.
