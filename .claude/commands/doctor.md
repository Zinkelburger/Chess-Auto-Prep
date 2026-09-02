---
description: Check whether this shared checkout is in a state where work will actually succeed — toolchain, fetched assets, the Flutter lock, the app driver, and the tracked agent contract.
allowed-tools: Bash(scripts/doctor.sh:*), Bash(scripts/ci.sh:*), Bash(git:*)
---

Run the checkout health check and act on it.

!`scripts/doctor.sh`

Read the report above and respond to the user with:

- **Blocking problems** (`BLOCK`) — these stop work. Fix them or say why you
  cannot. The common ones and their fixes:
  - untracked agent contract → `git add` the file; it exists only on this
    machine otherwise
  - missing fetched assets → `python3 tools/fetch_assets.py`
  - lint failures → `scripts/ci.sh lint` for detail, then fix
- **Notes** — not blocking, but they change how you should work:
  - Flutter lock held → your heavy jobs will queue; expect to wait, do not
    launch a second build
  - many dirty paths → another session is mid-refactor. If the tree does not
    compile, that is not yours to fix; use `driver.py start --worktree`
  - Flutter version ≠ the CI pin → `dart format` output can differ from CI's,
    so a tag build may fail the format gate even though local is green

If everything is clear, say so in one line and get on with the actual task —
do not narrate the passing checks.
