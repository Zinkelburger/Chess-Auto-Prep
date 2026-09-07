# Squashing and integration

Use these steps only in your own task worktree. Check the current branch and
base first, especially for a task stacked on another unmerged branch.

For a private, unmerged `codex/*` branch with checkpoint commits, squash before
marking its draft PR ready or handing it to the integrator. For a branch based
on main:

```sh
git fetch origin
git reset --soft $(git merge-base HEAD origin/main)
git commit
git push --force-with-lease
python3 scripts/agent_worktree.py --verify .
```

For stacked work, use the task's actual base instead of `origin/main` so the
squash does not absorb its dependency. Report that dependency in the handoff.
`--force-with-lease` is permitted only for converting checkpoints on your own
unmerged `codex/*` branch into its final commit. Never rewrite main, a merged
branch, another agent's branch, or a branch under review without warning the
reviewer.

Integrate from updated `origin/main` using pushed remote branches. Delete a
source branch/worktree only after the integrated result is pushed and the
remote PR/commit is confirmed on `origin/main`. Use `git branch -d`, never
`-D`, and remove the remote branch last.
