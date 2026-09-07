# Local integration and publishing

## Default: finish where the user can see it

Local `main` is the working version the user opens. `origin/main` is the
published version. `origin/backup/local-main` backs up committed development
without publishing it. Do not open PRs unless requested.

1. Start the task with `python3 scripts/agent_worktree.py <task-name>`. It uses
   current local `main`, including unpublished commits, not stale `origin/main`
   or whichever feature branch happens to launch it. Existing task worktrees
   can continue their own work.
2. Edit and run the relevant checks in the task worktree. Commit and push to
   its `codex/*` branch; checkpoint commits are fine. Run
   `python3 scripts/agent_worktree.py --verify .`.
3. Run `python3 scripts/agent_integrate.py` from that task worktree. It finds
   the main checkout, serializes integrations, advances it with a fast-forward,
   pushes `HEAD` to `origin/backup/local-main` and verifies that remote SHA.
   This is authorized routine completion, not an approval handoff.
4. If main advanced, merge local `main` into the task branch, resolve conflicts
   there, rerun relevant checks and push before retrying. Do not reset main to
   the task or base new integration on `origin/main`.
5. Git may carry non-overlapping unfinished main edits through a fast-forward.
   Overlapping edits must stay untouched: do not auto-stash, commit, discard or
   overwrite them. Identify the blocked paths and coordinate with their owner.
   Main's existing uncommitted edits are not covered by the committed backup.
6. Report the integrated SHA, backup, checks and where to see the changes.
   Updating source does not hot-reload an already running desktop binary; if
   needed, explain that the normal app must be rebuilt/restarted. Only launch
   a visible preview when requested.

The helper does not run tests for you. Use the task's relevant local checks
before integration. Full GitHub CI runs on `backup/local-main`; fix regressions
from your task and keep the batch unpublished until its required checks pass.
A failed backup push is recoverable: keep the worktrees and retry integration.
Never force-push the backup to hide divergence from another machine.

## Publish a batch only when requested

Keep local main's useful history. To produce a compact published history:

1. Fetch `origin`, snapshot the backed-up local main SHA and create a durable
   publication worktree/branch from current `origin/main`. Use an explicit
   `git worktree add -b codex/<publication-name> <durable-path> origin/main`
   and push the publication branch before editing it.
2. Merge the snapshot with `git merge --squash <snapshot-sha>` in that clean
   publication worktree and commit the batch. Resolve any upstream conflicts
   there. Keep a version/release bump as its own commit.
   Then prepare it using its own committed `scripts/agent_worktree.py
   --prepare . --assets-from /path/to/main-checkout` before running checks;
   preparing from a different checkout before the squash could copy newer
   workflow files into the clean publication input.
3. Push that publication branch, run the full required checks on its exact
   HEAD (local bounded checks or GitHub CI via workflow dispatch), and then
   fast-forward `origin/main` with the explicit `HEAD:refs/heads/main` refspec.
   If the remote advanced, reconcile and revalidate; never force-push it.
4. Merge the published commit back into a task worktree based on local main,
   validate any conflict resolutions, then use the usual integration helper.
   This records published ancestry without resetting the user's local history
   or absorbing later development into the already published batch.

Do not squash/reset the shared local main while other tasks are based on it.
Keep task branches until their commits are included in local main and its
verified remote backup. Remove only clean, unused worktrees; use `git branch -d`
and remove the remote task branch last. No cleanup is required to finish a task.

This uses Git's documented [fast-forward merges and squash option](https://git-scm.com/docs/git-merge)
and [explicit push refspecs](https://git-scm.com/docs/git-push). A squash creates
a new commit without the development branch's ancestry, which is why publishing
uses a separate worktree and records that commit back in development afterward.
