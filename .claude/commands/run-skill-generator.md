---
description: Create or improve a repository skill using the installed skill-creator.
argument-hint: [skill to create or improve]
---

Create or improve a repository skill for $ARGUMENTS using the installed
`skill-creator` skill. If unavailable, report that and author it directly;
do not assume an installation is active in the current session.

Read `docs/agents/README.md` for instruction ownership and the relevant guide
for the skill's domain. Keep trigger descriptions precise and supporting
material on demand. Track skill files in git and keep both `.agents/skills/`
and `.claude/skills/` entrypoints aligned. Use stdlib Python/plain bash for
helpers so running a skill does not require installing dependencies.

Compose existing app-driver and MCP skills instead of duplicating launchers
or reading the user's databases by hand. Follow AGENTS.md for worktrees,
checks and handoff. Validate frontmatter with `scripts/doctor.sh`; exercise the
skill's commands in the task worktree using disposable data and report what
was actually verified. Keep permissions and hook behavior in `.claude/settings.json`
and `scripts/hooks/flutter_gate.sh`, not copied into skill prose.
