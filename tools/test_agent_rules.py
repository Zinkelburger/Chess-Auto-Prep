#!/usr/bin/env python3
"""Offline integration checks for native rule generation and drift detection."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class AgentRulesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        shutil.copy2(ROOT / 'scripts/sync_agent_rules.py', self.root / 'scripts')
        shutil.copy2(ROOT / 'AGENTS.md', self.root)
        shutil.copytree(ROOT / 'docs/agents', self.root / 'docs/agents')
        self.assertEqual(self.run_rules().returncode, 0)

    def run_rules(self, *args):
        return subprocess.run(
            [sys.executable, str(self.root / 'scripts/sync_agent_rules.py'), *args],
            cwd=self.root, text=True, capture_output=True,
        )

    def test_generation_is_idempotent_and_references_resolve(self):
        paths = [self.root / 'CLAUDE.md',
                 *self.root.glob('.claude/rules/*.md'),
                 *self.root.glob('.cursor/rules/*.mdc')]
        before = {p: p.read_bytes() for p in paths}
        self.assertEqual(self.run_rules('--check').returncode, 0)
        self.assertEqual(self.run_rules().returncode, 0)
        self.assertEqual(before, {p: p.read_bytes() for p in paths})
        for path in paths:
            for line in path.read_text().splitlines():
                if line.startswith('@'):
                    base = self.root if path.suffix == '.mdc' else path.parent
                    self.assertTrue((base / line[1:]).is_file(), (path, line))

    def test_check_rejects_drift_without_repairing_it(self):
        path = self.root / '.cursor/rules/ui.mdc'
        changed = path.read_text().replace('alwaysApply: false', 'alwaysApply: true')
        path.write_text(changed)
        result = self.run_rules('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('.cursor/rules/ui.mdc', result.stderr)
        self.assertEqual(path.read_text(), changed)

    def test_check_rejects_missing_sources_and_excessive_root(self):
        (self.root / 'docs/agents/dart.md').unlink()
        (self.root / 'AGENTS.md').write_text('rule\n' * 121)
        result = self.run_rules('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing docs/agents/dart.md', result.stderr)
        self.assertIn('AGENTS.md exceeds 120 lines', result.stderr)

    def test_generation_preserves_and_reports_retired_rules(self):
        path = self.root / '.cursor/rules/agent-workflow.mdc'
        path.write_text('custom policy\n')
        result = self.run_rules()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('retired rule still exists', result.stderr)
        self.assertEqual(path.read_text(), 'custom policy\n')


if __name__ == '__main__':
    unittest.main()
