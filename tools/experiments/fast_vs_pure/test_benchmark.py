"""Guards against invalid or destructive performance comparisons (no engines)."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import benchmark


class MeasurementTest(unittest.TestCase):
    def test_empty_sqlite_journal_does_not_invalidate_a_stable_book(self):
        with tempfile.TemporaryDirectory() as temp:
            db = Path(temp) / 'book.db'
            db.write_bytes(b'database')
            before = benchmark.fingerprint(db)
            wal = Path(str(db) + '-wal')
            wal.touch()
            self.assertEqual(benchmark.fingerprint(db), before)
            wal.write_bytes(b'new pages')
            self.assertNotEqual(benchmark.fingerprint(db), before)
            wal.unlink()
            db.write_bytes(b'changed database')
            self.assertNotEqual(benchmark.fingerprint(db), before)

    def test_an_unfinished_search_never_gets_a_speedup_claim(self):
        with tempfile.TemporaryDirectory() as temp:
            fast = dict(complete=True, build_ms=10, nodes=3, root_move='e2e4')
            pure = dict(complete=False, build_ms=90000, nodes=10, root_move=None)
            out = Path(temp)
            benchmark.report(out, {'unfinished': {'pure': pure, 'fast': fast}})
            row = next(line for line in (out / 'comparison.md').read_text().splitlines()
                       if line.startswith('| unfinished |'))
            self.assertNotIn('×', row)
            self.assertIn('unresolved', row)
            self.assertFalse(json.loads((out / 'results.json').read_text())['unfinished']['pure']['complete'])

    def test_reusing_output_is_rejected_without_overwriting_measurements(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / 'measurements'
            out.mkdir()
            settings = out / 'settings.json'
            settings.write_text('original measurements')
            db = Path(temp) / 'master.db'
            db.write_bytes(b'database')
            run = subprocess.run([sys.executable, str(Path(benchmark.__file__)), str(out),
                                  '--master-db', str(db)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 2)
            self.assertIn('new or empty directory', run.stderr)
            self.assertEqual(settings.read_text(), 'original measurements')
            self.assertEqual(list(out.iterdir()), [settings])


if __name__ == '__main__':
    unittest.main()
