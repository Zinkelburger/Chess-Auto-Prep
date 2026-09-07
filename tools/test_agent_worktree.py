#!/usr/bin/env python3
"""Offline tests for durable worktree creation and handoff verification."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


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

    def test_new_task_starts_from_local_main_not_callers_branch(self):
        with tempfile.TemporaryDirectory(dir=ROOT.parent) as temp:
            checkout, remote = self.make_repository(Path(temp))
            run(checkout, 'branch', 'codex/older-task')
            (checkout / 'README').write_text('unpublished development\n')
            run(checkout, 'add', 'README')
            run(checkout, 'commit', '-m', 'local development')
            local_main = run(checkout, 'rev-parse', 'HEAD')
            run(checkout, 'switch', 'codex/older-task')
            fake_home = Path(temp) / 'home'
            with patch.object(agent_worktree, 'ROOT', checkout), \
                    patch.object(agent_worktree.Path, 'home', return_value=fake_home), \
                    patch.object(agent_worktree, 'prepare'), \
                    patch('sys.argv', ['agent_worktree.py', 'new-task']):
                agent_worktree.main()
            target = fake_home / '.local/share/chess-prep/worktrees/new-task'
            self.assertEqual(run(target, 'rev-parse', 'HEAD'), local_main)
            self.assertEqual(run(remote, 'rev-parse', 'refs/heads/codex/new-task'), local_main)
            self.assertNotEqual(run(remote, 'rev-parse', 'refs/heads/main'), local_main)

    def test_prepare_migrates_rules_and_preserves_local_changes(self):
        with tempfile.TemporaryDirectory(dir=ROOT.parent) as temp:
            checkout, _ = self.make_repository(Path(temp))
            retired = agent_worktree.RETIRED_WORKFLOW_FILES
            for relative in retired:
                path = checkout / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('old rule\n')
            (checkout / 'AGENTS.md').write_text('old root policy\n')
            run(checkout, 'add', '.')
            run(checkout, 'commit', '-m', 'old guidance')
            # Preserve both unstaged and staged edits, and untracked rules.
            for relative in retired[:2]:
                (checkout / relative).write_text('user edit\n')
            run(checkout, 'add', retired[1])
            run(checkout, 'rm', '--cached', retired[2])

            agent_worktree.sync_workflow(checkout, ROOT)

            for relative in retired[:2]:
                self.assertEqual((checkout / relative).read_text(), 'user edit\n')
            self.assertTrue((checkout / retired[2]).is_file())
            for relative in retired[3:]:
                self.assertFalse((checkout / relative).exists())
            for relative in ('AGENTS.md', 'CLAUDE.md', 'scripts/sync_agent_rules.py'):
                self.assertEqual((checkout / relative).read_bytes(),
                                 (ROOT / relative).read_bytes())
            for pattern in ('docs/agents/*.md', '.claude/rules/*.md', '.cursor/rules/*.mdc'):
                for source in ROOT.glob(pattern):
                    self.assertEqual((checkout / source.relative_to(ROOT)).read_bytes(),
                                     source.read_bytes())


if __name__ == '__main__':
    unittest.main()
