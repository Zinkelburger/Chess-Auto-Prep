# Maintaining agent instructions

## Ownership and loading

`AGENTS.md` owns universal policy. Keep it under 120 lines; this is a local
maintenance budget, not a model context limit. Put only requirements that
matter to most tasks there. Keep tool counts, resource-limit implementation,
architecture history and detailed examples out of startup instructions.

`docs/agents/` owns task-specific guidance. The root's routing table tells an
agent when to read each guide; it does not import all of them. Keep these
links conditional. Existing skills own specialized procedures and commands.

| Client | Startup | Task-specific loading |
|---|---|---|
| Codex | Root `AGENTS.md` | Explicit conditional links in that file |
| Claude Code | `CLAUDE.md` imports `AGENTS.md` | `.claude/rules/*.md` uses `paths` and relative imports |
| Cursor | Root `AGENTS.md` | `.cursor/rules/*.mdc` uses globs and file references; none always apply |

Codex builds its discovered instruction chain from the repository root to
its starting directory. Do not assume a new nested AGENTS.md will be loaded
when a root-started task later edits that subtree; keep the root routing table.
Claude imports consume context when their containing rule loads, so importing
every guide from the root CLAUDE.md would defeat this layout.

Dart rules apply to Dart files; UI rules attach to widget/screen/theme paths
and UI tests. The root also routes UI work outside those paths. Documentation
rules attach to documentation edits; behavior/API/layout changes trigger the
same guide through the Dart guide or root routing table. Tooling and Git
procedures are read on demand rather than attached to every file in `tools/`.

## Editing and validation

Edit the canonical policy/guide, not a native adapter. If a trigger changes,
edit `SCOPES` in `scripts/sync_agent_rules.py`, then run:

```sh
python3 scripts/sync_agent_rules.py
scripts/ci.sh lint
```

The generator writes only tiny references. Its `--check` mode runs in local
lint and GitHub CI, rejecting adapter drift, retired rules, missing guides and
root-policy growth. Check links and representative path scopes when changing
the layout. This validates repository configuration, not a live client session.
Keep the guidance files in `scripts/agent_worktree.py`'s `WORKFLOW_FILES` so
preparing older worktrees carries the complete policy, not broken references.

Do not copy canonical policy into commands or skills. Keep their trigger
metadata and task steps; link to shared requirements. Add mechanical checks
when a recurring failure can be detected reliably, rather than adding another
paragraph for every incident. Skill entrypoints currently exist in both
`.agents/skills/` and `.claude/skills/`; keep matching skills aligned.

## Sources

Loading behavior checked against the official documentation on 2026-09-07:
[Codex AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md),
[Claude memory and path-scoped rules](https://code.claude.com/docs/en/memory),
and [Cursor rules and file references](https://cursor.com/docs/rules).
