#!/usr/bin/env python3
"""Create an agent worktree, or prepare one made by Codex/Claude/Cursor."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


WORKFLOW_FILES = (
    'AGENTS.md', 'CLAUDE.md', '.cursor/rules/agent-workflow.mdc',
    '.claude/settings.json', '.claude/commands/doctor.md',
    '.claude/commands/drive.md', '.claude/commands/gate.md',
    '.agents/skills/run-chess-auto-prep/SKILL.md',
    '.agents/skills/run-chess-auto-prep/driver.py',
    '.claude/skills/run-chess-auto-prep/SKILL.md',
    '.claude/skills/run-chess-auto-prep/driver.py',
    'scripts/agent_job.py', 'scripts/agent_worktree.py', 'scripts/app_driver.py',
    'scripts/ci.sh', 'scripts/doctor.sh', 'scripts/setup_agent_display.sh',
    'scripts/hooks/flutter_gate.sh', 'scripts/test_tools.sh',
    'scripts/check_coverage.sh', 'scripts/health_log.sh',
    'scripts/oom_containment.sh', 'tools/test_agent_jobs.py',
)


def sync_workflow(target: Path, source: Path):
    """Carry the current launcher into new worktrees, preserving local edits."""
    if target.resolve() == source.resolve():
        return
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
    parser.add_argument('--assets-from', type=Path, default=ROOT)
    args = parser.parse_args()
    if args.prepare:
        target = args.prepare.resolve()
    else:
        if not args.name or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]*', args.name):
            parser.error('provide a simple task name, or --prepare EXISTING_WORKTREE')
        target = Path.home() / '.local/share/chess-prep/worktrees' / args.name
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['git', 'worktree', 'add', '-b', f'codex/{args.name}', str(target), 'HEAD'], cwd=ROOT, check=True)
    prepare(target, args.assets_from.resolve())


if __name__ == '__main__':
    main()
