#!/usr/bin/env python3
"""Create, prepare, or verify a safely backed-up agent worktree."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


WORKFLOW_FILES = (
    'AGENTS.md', 'CLAUDE.md', 'scripts/sync_agent_rules.py',
    'docs/agents/README.md', 'docs/agents/dart.md', 'docs/agents/ui.md',
    'docs/agents/documentation.md', 'docs/agents/tooling.md', 'docs/agents/git.md',
    '.cursor/rules/dart.mdc', '.cursor/rules/ui.mdc',
    '.cursor/rules/documentation.mdc', '.claude/rules/dart.md',
    '.claude/rules/ui.md', '.claude/rules/documentation.md',
    '.claude/settings.json', '.claude/commands/doctor.md',
    '.claude/commands/drive.md', '.claude/commands/gate.md',
    '.claude/commands/run-skill-generator.md',
    '.agents/skills/run-chess-auto-prep/SKILL.md',
    '.agents/skills/run-chess-auto-prep/driver.py',
    '.claude/skills/run-chess-auto-prep/SKILL.md',
    '.claude/skills/run-chess-auto-prep/driver.py',
    'scripts/agent_job.py', 'scripts/agent_worktree.py', 'scripts/app_driver.py',
    'scripts/ci.sh', 'scripts/doctor.sh', 'scripts/setup_agent_display.sh',
    'scripts/hooks/flutter_gate.sh', 'scripts/test_tools.sh',
    'scripts/check_coverage.sh', 'scripts/health_log.sh',
    'scripts/oom_containment.sh', 'tools/test_agent_jobs.py',
    'tools/test_agent_worktree.py', 'tools/test_agent_rules.py',
)

# Remove superseded rules when preparing older worktrees, but only if clean.
RETIRED_WORKFLOW_FILES = (
    '.cursor/rules/agent-workflow.mdc',
    '.cursor/rules/app-documentation.mdc',
    '.cursor/rules/cross-platform-paths.mdc',
    '.cursor/rules/flutter-mounted-guard.mdc',
    '.cursor/rules/shortcut-tooltips.mdc',
)

TEMPORARY_ROOT = Path('/tmp')


def git_text(target: Path, *args: str) -> str:
    return subprocess.check_output(
        ['git', *args], cwd=target, text=True, stderr=subprocess.DEVNULL,
    ).strip()


def git_optional_text(target: Path, *args: str) -> str:
    result = subprocess.run(
        ['git', *args], cwd=target, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return result.stdout.strip() if result.returncode == 0 else ''


def branch_name(target: Path) -> str | None:
    result = subprocess.run(
        ['git', 'symbolic-ref', '--quiet', '--short', 'HEAD'], cwd=target,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def is_temporary(target: Path) -> bool:
    try:
        target.resolve().relative_to(TEMPORARY_ROOT)
        return True
    except ValueError:
        return False


def require_durable_branch(target: Path, branch: str | None) -> None:
    if branch is not None and is_temporary(target):
        raise RuntimeError(
            f'Branch-backed worktrees may not live in /tmp: {target}. '
            'Use: python3 scripts/agent_worktree.py <task-name>',
        )


def push_branch(target: Path, branch: str | None) -> None:
    """Give every editing branch an off-machine ref before work starts."""
    if branch is None or branch in {'main', 'master'}:
        return
    require_durable_branch(target, branch)
    remotes = git_text(target, 'remote').splitlines()
    if 'origin' not in remotes:
        raise RuntimeError(
            f'{branch} has no origin remote; refusing an unbacked editing worktree',
        )
    subprocess.run(
        ['git', 'push', '--set-upstream', 'origin',
         f'HEAD:refs/heads/{branch}'],
        cwd=target, check=True,
    )


def verify_handoff(target: Path) -> None:
    """Refuse handoff until every byte is committed and present on the remote."""
    target = target.resolve()
    branch = branch_name(target)
    if branch is None:
        raise RuntimeError('Cannot hand off a detached HEAD; use an editing branch')
    require_durable_branch(target, branch)

    dirty = git_text(target, 'status', '--porcelain')
    if dirty:
        count = len(dirty.splitlines())
        raise RuntimeError(f'{count} uncommitted path(s); commit and push them first')

    remote = git_optional_text(
        target, 'config', '--get', f'branch.{branch}.remote',
    )
    merge_ref = git_optional_text(
        target, 'config', '--get', f'branch.{branch}.merge',
    )
    if not remote or not merge_ref:
        raise RuntimeError(
            f'{branch} has no upstream; run: git push -u origin HEAD',
        )
    if remote == '.':
        raise RuntimeError(f'{branch} tracks a local branch, not an off-machine remote')

    head = git_text(target, 'rev-parse', 'HEAD')
    result = subprocess.run(
        ['git', 'ls-remote', '--exit-code', remote, merge_ref], cwd=target,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f'Cannot find {remote}/{merge_ref.removeprefix("refs/heads/")}; '
            'push the branch before handoff',
        )
    remote_head = result.stdout.split()[0]
    if remote_head != head:
        raise RuntimeError(
            f'{branch} is not fully pushed: local {head[:8]}, '
            f'remote {remote_head[:8]}',
        )
    print(f'Verified handoff: {branch} at {head[:8]} is clean and on {remote}')


def sync_workflow(target: Path, source: Path):
    """Carry the current launcher into new worktrees, preserving local edits."""
    if target.resolve() == source.resolve():
        return
    for relative in RETIRED_WORKFLOW_FILES:
        dst = target / relative
        if (source / relative).exists() or not dst.is_file():
            continue
        tracked = git_optional_text(target, 'ls-files', '--', relative)
        clean = subprocess.run(
            ['git', 'diff', '--quiet', 'HEAD', '--', relative], cwd=target,
        ).returncode == 0
        if tracked and clean:
            dst.unlink()
        else:
            print(f'Kept locally modified retired rule: {dst}')
    for relative in WORKFLOW_FILES:
        src, dst = source / relative, target / relative
        if not src.is_file() or (dst.is_file() and src.read_bytes() == dst.read_bytes()):
            continue
        if dst.exists():
            tracked = subprocess.run(['git', 'ls-files', '--error-unmatch', relative],
                                     cwd=target, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL).returncode == 0
            clean = subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--', relative],
                                   cwd=target).returncode == 0
            if not tracked or not clean:
                print(f'Kept locally modified workflow file: {dst}')
                continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def prepare(target: Path, source: Path):
    # Only immutable, gitignored engine/model assets are shared. Each checkout
    # keeps its own .dart_tool, generated plugins, build output, and app profile.
    sync_workflow(target, ROOT)
    files = subprocess.check_output(['git', 'ls-files', '--others', '--ignored',
                                     '--exclude-standard', '-z', 'assets'], cwd=source)
    for relative in filter(None, files.decode().split('\0')):
        src, dst = source / relative, target / relative
        if src.is_file() and not dst.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.symlink_to(src)
    flutter = Path.home() / 'sdk/flutter/bin/flutter'
    subprocess.run([str(flutter) if flutter.exists() else 'flutter', 'pub', 'get'], cwd=target, check=True)
    print(f'Ready: {target}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name', nargs='?')
    parser.add_argument('--prepare', type=Path)
    parser.add_argument('--verify', type=Path)
    parser.add_argument('--assets-from', type=Path, default=ROOT)
    args = parser.parse_args()
    if args.verify:
        if args.name or args.prepare:
            parser.error('--verify cannot be combined with a name or --prepare')
        verify_handoff(args.verify)
        return
    if args.prepare:
        if args.name:
            parser.error('--prepare cannot be combined with a name')
        target = args.prepare.resolve()
    else:
        if not args.name or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]*', args.name):
            parser.error('provide a simple task name, or --prepare EXISTING_WORKTREE')
        target = Path.home() / '.local/share/chess-prep/worktrees' / args.name
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['git', 'worktree', 'add', '-b', f'codex/{args.name}', str(target), 'HEAD'], cwd=ROOT, check=True)
    branch = branch_name(target)
    require_durable_branch(target, branch)
    push_branch(target, branch)
    prepare(target, args.assets_from.resolve())


if __name__ == '__main__':
    main()
