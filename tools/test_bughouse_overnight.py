"""Manual population controls must be bounded, resumable and opt-in."""
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from bughouse_db import overnight as o


class OvernightTests(unittest.TestCase):
    def test_start_creates_one_bounded_service_without_timer(self):
        with patch.object(o.os, 'sched_getaffinity', return_value=set(range(8))), \
             patch.object(o.subprocess, 'run', return_value=subprocess.CompletedProcess([], 3)) as run:
            o.main(['start', '--hours', '8', '--cores', '8'])
        command = run.call_args_list[-1].args[0]
        self.assertIn('--property=CPUQuota=800%', command)
        self.assertIn('--property=MemoryMax=6G', command)
        self.assertIn('--property=RuntimeMaxSec=29400', command)
        self.assertFalse(any('timer' in arg for arg in command))
        self.assertIn('run', command)

    def test_second_start_refuses_active_service(self):
        with patch.object(o.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            with self.assertRaises(SystemExit): o.main(['start'])
        self.assertEqual(run.call_count, 1)

    def test_local_run_keeps_800_and_divides_total_cores(self):
        with tempfile.TemporaryDirectory() as temp:
            fics = Path(temp) / 'fics.db'; fics.touch()
            args = o.parser().parse_args(['run', '--fics', str(fics), '--local-only'])
            with patch.object(o.expectimax, 'seed') as seed, patch.object(o.expectimax, 'run') as run, \
                 patch.object(o, 'shared_positions') as remote:
                o.run(args)
                seed.assert_called_once()
                remote.assert_not_called()
                used = run.call_args.args[0]
                self.assertEqual((used.nodes, used.cores, used.workers), (800, 4, 2))
                self.assertIsNone(used.publish_to)

    def test_invalid_resources_never_start_anything(self):
        with patch.object(o.subprocess, 'run') as run:
            with self.assertRaises(SystemExit): o.main(['start', '--cores', '3', '--workers', '2'])
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
