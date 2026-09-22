#!/usr/bin/env python3
"""Reject ambiguous check batches before they launch expensive work."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CiDispatchTest(unittest.TestCase):
    def test_misplaced_focused_target_fails_before_first_step(self):
        for args in (
            ['analyze', 'lint', 'test', 'test/example_test.dart'],
            ['analyze', 'integration', 'integration_test/example_test.dart'],
            ['lint', 'not-a-step'],
        ):
            with self.subTest(args=args):
                result = subprocess.run(
                    ['bash', str(ROOT / 'scripts/ci.sh'), *args],
                    cwd=ROOT, capture_output=True, text=True, timeout=5,
                )
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, '')
                self.assertIn('Run focused tests separately', result.stderr)
                self.assertNotIn('agent-job:', result.stderr)


if __name__ == '__main__':
    unittest.main()
