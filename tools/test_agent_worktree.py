#!/usr/bin/env python3
"""Offline tests for durable worktree creation and handoff verification."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    'agent_worktree', ROOT / 'scripts/agent_worktree.py',
)
agent_worktree = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(agent_worktree)


def run(directory: Path, *args: str) -> str:
    return subprocess.check_output(
        ['git', *args], cwd=directory, text=True,
    ).strip()


class AgentWorktreeTests(unittest.TestCase):
    def make_repository(self, directory: Path) -> tuple[Path, Path]:
        remote = directory / 'remote.git'
        checkout = directory / 'checkout'
        subprocess.run(['git', 'init', '--bare', str(remote)], check=True,
                       stdout=subprocess.DEVNULL)
        subprocess.run(['git', 'init', str(checkout)], check=True,
                       stdout=subprocess.DEVNULL)
        run(checkout, 'config', 'user.name', 'Agent Test')
        run(checkout, 'config', 'user.email', 'agent@example.invalid')
        (checkout / 'README').write_text('base\n')
        run(checkout, 'add', 'README')
        run(checkout, 'commit', '-m', 'base')
        run(checkout, 'branch', '-M', 'main')
        run(checkout, 'remote', 'add', 'origin', str(remote))
        run(checkout, 'push', '-u', 'origin', 'main')
        return checkout, remote

    def test_pushes_editing_branch_and_verifies_exact_remote_head(self):
        with tempfile.TemporaryDirectory(dir=ROOT.parent) as temp:
            checkout, remote = self.make_repository(Path(temp))
            run(checkout, 'switch', '-c', 'codex/safe-task')
            agent_worktree.push_branch(checkout, 'codex/safe-task')
            agent_worktree.verify_handoff(checkout)
            remote_head = subprocess.check_output(
                ['git', 'ls-remote', str(remote),
                 'refs/heads/codex/safe-task'], text=True,
            ).split()[0]
            self.assertEqual(remote_head, run(checkout, 'rev-parse', 'HEAD'))

    def test_handoff_rejects_dirty_and_unpushed_work(self):
        with tempfile.TemporaryDirectory(dir=ROOT.parent) as temp:
            checkout, _ = self.make_repository(Path(temp))
            run(checkout, 'switch', '-c', 'codex/unfinished')
            agent_worktree.push_branch(checkout, 'codex/unfinished')
            (checkout / 'README').write_text('dirty\n')
            with self.assertRaisesRegex(RuntimeError, 'uncommitted'):
                agent_worktree.verify_handoff(checkout)
            run(checkout, 'add', 'README')
            run(checkout, 'commit', '-m', 'local only')
            with self.assertRaisesRegex(RuntimeError, 'not fully pushed'):
                agent_worktree.verify_handoff(checkout)

    def test_handoff_rejects_branch_without_upstream(self):
        with tempfile.TemporaryDirectory(dir=ROOT.parent) as temp:
            checkout, _ = self.make_repository(Path(temp))
            run(checkout, 'switch', '-c', 'codex/local-only')
            with self.assertRaisesRegex(RuntimeError, 'has no upstream'):
                agent_worktree.verify_handoff(checkout)

    def test_branch_backed_tmp_worktree_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'may not live in /tmp'):
            agent_worktree.require_durable_branch(
                Path('/tmp/disappearing-task'), 'codex/disappearing-task',
            )
        agent_worktree.require_durable_branch(
            Path('/tmp/disposable-preview'), None,
        )


if __name__ == '__main__':
    unittest.main()
