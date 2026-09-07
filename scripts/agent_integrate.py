#!/usr/bin/env python3
"""Land a tested task on local main and back it up without publishing origin/main."""
import argparse
from contextlib import contextmanager
import fcntl
from pathlib import Path
import subprocess

from agent_worktree import branch_name, git_text, verify_handoff

BACKUP_REF = 'refs/heads/backup/local-main'


def run(checkout: Path, *args: str) -> None:
    subprocess.run(['git', *args], cwd=checkout, check=True)


def main_checkout(task: Path) -> Path:
    path = None
    for field in git_text(task, 'worktree', 'list', '--porcelain', '-z').split('\0'):
        if field.startswith('worktree '):
            path = Path(field.removeprefix('worktree '))
        elif field == 'branch refs/heads/main' and path is not None:
            return path
    raise RuntimeError('No local main checkout found; do not substitute origin/main')


@contextmanager
def integration_lock(checkout: Path):
    common = Path(git_text(checkout, 'rev-parse', '--path-format=absolute', '--git-common-dir'))
    with (common / 'agent-integration.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError('Another integration is running; retry after it finishes') from exc
        yield


def is_ancestor(checkout: Path, ancestor: str, descendant: str) -> bool:
    result = subprocess.run(
        ['git', 'merge-base', '--is-ancestor', ancestor, descendant], cwd=checkout,
    )
    if result.returncode not in (0, 1):
        raise RuntimeError('Could not compare task and local main history')
    return result.returncode == 0


def verify_main(checkout: Path) -> None:
    if branch_name(checkout) != 'main':
        raise RuntimeError(f'{checkout} is no longer on main')
    head = git_text(checkout, 'rev-parse', 'HEAD')
    remote = git_text(checkout, 'ls-remote', '--exit-code', 'origin', BACKUP_REF).split()[0]
    if remote != head:
        raise RuntimeError('Local main is not backed up; rerun agent_integrate.py from the task')
    print(f'Local main at {head[:8]} is backed up on origin/backup/local-main: {checkout}')
    dirty = git_text(checkout, 'status', '--porcelain')
    if dirty:
        print('Existing uncommitted main edits remain local; they are not part of this backup:')
        print(dirty)


def integrate(task: Path) -> None:
    task = task.resolve()
    branch = branch_name(task)
    if branch is None or not branch.startswith('codex/'):
        raise RuntimeError('Run from a clean, pushed codex/* task worktree')
    verify_handoff(task)
    head = git_text(task, 'rev-parse', 'HEAD')
    checkout = main_checkout(task)
    with integration_lock(checkout):
        if branch_name(checkout) != 'main':
            raise RuntimeError('The main checkout changed branches; retry after checking it')
        current = git_text(checkout, 'rev-parse', 'HEAD')
        if is_ancestor(checkout, head, current):
            print('Task is already integrated; verifying/backing up current local main')
        elif is_ancestor(checkout, current, head):
            # Git refuses overlapping worktree/index changes. Never stash, reset,
            # or overwrite ignored files to make a merge succeed.
            run(checkout, 'merge', '--ff-only', '--no-autostash',
                '--no-overwrite-ignore', '--no-edit', head)
        else:
            raise RuntimeError(
                'Local main advanced. Merge main into the task worktree, resolve there, '
                'rerun relevant checks, commit/push, then retry integration',
            )
        try:
            run(checkout, 'push', 'origin', f'HEAD:{BACKUP_REF}')
        except subprocess.CalledProcessError as exc:
            raise RuntimeError(
                'Task is on local main but its backup push failed. '
                'Keep both worktrees and retry; do not force-push or undo the integration',
            ) from exc
        verify_main(checkout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify', action='store_true', help='verify local main backup only')
    args = parser.parse_args()
    task = Path.cwd()
    if args.verify:
        checkout = main_checkout(task)
        with integration_lock(checkout):
            verify_main(checkout)
    else:
        integrate(task)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f'agent-integrate: {exc}')
