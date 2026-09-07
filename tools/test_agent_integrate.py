#!/usr/bin/env python3
"""Exercise local integration against disposable repos and a real bare remote."""
import fcntl
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'scripts/agent_integrate.py'


def git(checkout, *args):
    return subprocess.check_output(
        ['git', *args], cwd=checkout, text=True, stderr=subprocess.PIPE,
    ).strip()


class AgentIntegrateTests(unittest.TestCase):
    def setUp(self):
        # Branch-backed fixture worktrees must also be outside /tmp.
        self.temp = tempfile.TemporaryDirectory(dir=ROOT.parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.main = self.root / 'main checkout'
        self.task = self.root / 'task checkout'
        self.remote = self.root / 'remote.git'
        git(self.root, 'init', '--bare', str(self.remote))
        git(self.root, 'init', '-b', 'main', str(self.main))
        git(self.main, 'config', 'user.name', 'Agent Test')
        git(self.main, 'config', 'user.email', 'agent@example.invalid')
        for name in ('task.txt', 'user.txt'):
            (self.main / name).write_text('base\n')
        git(self.main, 'add', '.')
        git(self.main, 'commit', '-m', 'base')
        self.base = git(self.main, 'rev-parse', 'HEAD')
        git(self.main, 'remote', 'add', 'origin', str(self.remote))
        git(self.main, 'push', '-u', 'origin', 'main')
        git(self.main, 'worktree', 'add', '-b', 'codex/task', str(self.task))
        self.commit(self.task, 'task.txt', 'task change\n')
        git(self.task, 'push', '-u', 'origin', 'HEAD')
        self.head = git(self.task, 'rev-parse', 'HEAD')

    def commit(self, checkout, path, content):
        (checkout / path).write_text(content)
        git(checkout, 'add', path)
        git(checkout, 'commit', '-m', path)

    def integrate(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args], cwd=self.task,
            text=True, capture_output=True,
        )

    def remote_head(self, branch):
        return git(self.remote, 'rev-parse', f'refs/heads/{branch}')

    def test_lands_locally_backs_up_and_never_publishes(self):
        (self.main / 'user.txt').write_text('unfinished user edit\n')
        (self.main / 'untracked.txt').write_text('unfinished new file\n')
        result = self.integrate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(self.main, 'rev-parse', 'HEAD'), self.head)
        self.assertEqual(self.remote_head('backup/local-main'), self.head)
        self.assertEqual(self.remote_head('main'), self.base)
        self.assertEqual((self.main / 'task.txt').read_text(), 'task change\n')
        self.assertEqual((self.main / 'user.txt').read_text(), 'unfinished user edit\n')
        self.assertEqual((self.main / 'untracked.txt').read_text(), 'unfinished new file\n')
        self.assertIn('not part of this backup', result.stdout)
        self.assertEqual(self.integrate().returncode, 0)  # retry is safe
        self.assertEqual(self.integrate('--verify').returncode, 0)

    def test_overlapping_main_edit_is_not_stashed_or_overwritten(self):
        (self.main / 'task.txt').write_text('unfinished overlapping edit\n')
        result = self.integrate()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(git(self.main, 'rev-parse', 'HEAD'), self.base)
        self.assertEqual((self.main / 'task.txt').read_text(), 'unfinished overlapping edit\n')
        self.assertEqual(git(self.main, 'stash', 'list'), '')
        self.assertEqual(self.remote_head('main'), self.base)

    def test_ignored_file_in_main_is_not_overwritten(self):
        (self.main / '.git/info/exclude').write_text('ignored.txt\n')
        (self.main / 'ignored.txt').write_text('user ignored file\n')
        (self.task / 'ignored.txt').write_text('new tracked file\n')
        git(self.task, 'add', '-f', 'ignored.txt')
        git(self.task, 'commit', '-m', 'track file')
        git(self.task, 'push')
        result = self.integrate()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.main / 'ignored.txt').read_text(), 'user ignored file\n')
        self.assertEqual(git(self.main, 'rev-parse', 'HEAD'), self.base)

    def test_advanced_main_requires_integration_and_retest_in_task(self):
        self.commit(self.main, 'other.txt', 'another completed task\n')
        advanced = git(self.main, 'rev-parse', 'HEAD')
        result = self.integrate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Local main advanced', result.stderr)
        self.assertEqual(git(self.main, 'rev-parse', 'HEAD'), advanced)
        git(self.task, 'merge', '--no-edit', 'main')
        git(self.task, 'push')
        result = self.integrate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.main / 'other.txt').read_text(), 'another completed task\n')
        self.assertEqual(self.remote_head('main'), self.base)

    def test_failed_backup_keeps_local_integration_and_remote_history(self):
        git(self.task, 'switch', '-c', 'codex/other')
        self.commit(self.task, 'remote-only.txt', 'remote development\n')
        ahead = git(self.task, 'rev-parse', 'HEAD')
        git(self.task, 'push', 'origin', 'HEAD:refs/heads/backup/local-main')
        git(self.task, 'switch', 'codex/task')
        result = self.integrate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('on local main but its backup push failed', result.stderr)
        self.assertEqual(git(self.main, 'rev-parse', 'HEAD'), self.head)
        self.assertEqual(self.remote_head('backup/local-main'), ahead)
        self.assertEqual(self.remote_head('main'), self.base)

    def test_dirty_task_and_concurrent_integration_are_rejected(self):
        (self.task / 'task.txt').write_text('not tested or committed\n')
        result = self.integrate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('uncommitted', result.stderr)
        (self.task / 'task.txt').write_text('task change\n')
        with (self.main / '.git/agent-integration.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.integrate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Another integration is running', result.stderr)
        self.assertEqual(git(self.main, 'rev-parse', 'HEAD'), self.base)


if __name__ == '__main__':
    unittest.main()
