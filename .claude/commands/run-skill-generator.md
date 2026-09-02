---
description: Create or improve a Claude Code skill for this repo, using the official skill-creator generator plus this project's conventions.
argument-hint: [what the skill should do, or the name of an existing skill to improve]
---

Build or improve a skill for **this repository**.

Target: $ARGUMENTS

## Step 1 — use the real generator

Invoke the `skill-creator` skill (installed from the official marketplace as
`skill-creator@claude-plugins-official`). It owns the actual authoring loop:
capture intent → interview → draft → test prompts → eval → rewrite. Follow it.

If `skill-creator` is not in your skill list, it is not enabled in this
session. Install it, then tell the user it takes effect next session:

```
claude plugin install skill-creator@claude-plugins-official
```

Until then, author the skill by hand against the rules below — do not invent a
substitute workflow.

## Step 2 — hold it to this repo's constraints

A skill for Chess Auto Prep is only correct if it obeys the same rules a human
contributor does. Check every draft against these before showing it:

- **Skills live in `.claude/skills/<name>/SKILL.md`**, tracked in git.
  Anything untracked exists only on one machine and is worthless to the next
  agent — that is the bug `scripts/doctor.sh` checks for.
- **Never shell out to `flutter test|analyze|run|build|drive`, `dart test`, or
  `xvfb-run`.** A `PreToolUse` hook denies them. Heavy work goes through
  `scripts/ci.sh` (which takes the machine-wide flock) or
  `scripts/ci.sh with -- <cmd>` for anything else.
- **Driving the app** means `.claude/skills/run-chess-auto-prep/driver.py`, not
  a new launcher. If the skill needs to see the UI, compose with that driver
  rather than duplicating it.
- **The tree is shared** with other sessions and is routinely mid-refactor. A
  skill that assumes a clean, compiling tree will fail; prefer
  `driver.py start --worktree`, which builds HEAD in a snapshot.
- **Helper scripts must be stdlib-only Python or plain bash.** `driver.py` is
  stdlib-only on purpose — no pip install step may stand between an agent and
  running the skill.
- Read `CLAUDE.md` for the layering, decomposition, and type/colour rules; a
  skill that generates code must respect them or `scripts/ci.sh lint` fails.

## Step 3 — prove it before declaring victory

Do not report a skill as working because the file parses.

1. `python3 -c "import yaml,sys; yaml.safe_load(open('.claude/skills/<name>/SKILL.md').read().split('---')[1])"`
   — frontmatter must have `name` and a `description` that says *when to
   trigger*, not just what it does.
2. Actually run the skill's own commands end to end and paste the real output.
3. `scripts/doctor.sh` — must stay all-clear.
4. `git add` the skill. An untracked skill is not shipped.

Then tell the user, in one line each: what the skill does, what you ran to
verify it, and anything you could not verify.
