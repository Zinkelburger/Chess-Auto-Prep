---
name: run-chess-auto-prep
description: Build, run, drive and screenshot Chess Auto Prep on Linux. Uses a private headless display and test data by default; also owns focused local checks through the bounded job runner.
---

# Run Chess Auto Prep

Use `scripts/app_driver.py` from the task's own worktree. The `.agents` and
`.claude` driver entrypoints forward to this one implementation.

```
python3 scripts/app_driver.py start
python3 scripts/app_driver.py dump
python3 scripts/app_driver.py tap tooltip="App settings"
python3 scripts/app_driver.py type text="example" key=field-key
python3 scripts/app_driver.py scroll text="Section" dy=400
python3 scripts/app_driver.py ss settings
python3 scripts/app_driver.py reload
python3 scripts/app_driver.py status
python3 scripts/app_driver.py stop
```

`start` is headless: a private Xvfb display, a separate session bus and app
instance, and an isolated profile for config, databases, cache and Documents.
The status prints the profile; place any needed PGNs or test fixtures there.
It neither copies nor uses the user's saved accounts and databases. `ss` saves
a PNG from Flutter's layer tree; inspect the returned image after UI changes.
`start --visible` uses a real window only for requested demos or native desktop
behavior that needs testing. It still uses the isolated profile.

Driver state is per checkout. Work in your own worktree so another task cannot
navigate or stop your app. `start --src DIR` builds a specific checkout and
`start --worktree` creates a fresh HEAD snapshot; neither resets an existing
worktree. Prefer your own worktree when testing changes. `reload` and `restart`
operate only on that source tree. `log n=40` reads the tail of its log.

Builds, tests and the running test app share the bounded runner: two jobs per
machine, two CPUs and 8 GiB per job, 16 GiB combined. A running preview holds
one slot and its checkout reservation until stopped. Stop it before testing
that same checkout. Old exclusive-lock jobs finish before new jobs enter.

Targets can use exact `text=`, `tooltip=`, `key=`, `field=` or `x= y=`;
`index=N` disambiguates. Use `dump` instead of guessing coordinates. Hidden
routes may briefly appear during an animation; settle and inspect again.
`restart` resets in-memory app state but keeps the isolated profile.

```
scripts/ci.sh analyze lint
scripts/ci.sh test test/path_test.dart
scripts/ci.sh integration                 # real desktop app on private display
scripts/ci.sh with -- COMMAND             # bounded arbitrary heavy command
scripts/ci.sh status
```

Full PR checks run in GitHub CI. A full local suite on every commit is not
required; choose focused checks and report their results. If display setup is
missing, run `scripts/setup_agent_display.sh`. Never fall back to a visible
window or an uncapped command to work around a failed launcher.
