#!/usr/bin/env python3

import tempfile
import unittest
from pathlib import Path

import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from check_file_mutations import scan  # noqa: E402


class FileMutationLintTest(unittest.TestCase):
    def test_rejects_new_direct_writer(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "lib" / "feature.dart"
            source.parent.mkdir(parents=True)
            source.write_text(
                "import 'dart:io';\n"
                "Future<void> save(File f) => f.writeAsString('lost');\n",
                encoding="utf-8",
            )
            violations = scan(root)
            self.assertEqual(len(violations), 1)
            self.assertIn("feature.dart", violations[0])

    def test_ignores_read_only_io(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "lib" / "reader.dart"
            source.parent.mkdir(parents=True)
            source.write_text(
                "import 'dart:io';\n"
                "Future<String> read(File f) => f.readAsString();\n",
                encoding="utf-8",
            )
            self.assertEqual(scan(root), [])

    def test_rejects_destructive_move_and_random_access_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "lib" / "feature.dart"
            source.parent.mkdir(parents=True)
            source.write_text(
                "import 'dart:io';\n"
                "Future<void> move(File f) async => f.rename('elsewhere');\n"
                "Future<void> cut(RandomAccessFile f) => f.truncate(0);\n",
                encoding="utf-8",
            )
            violations = scan(root)
            self.assertEqual(len(violations), 1)
            self.assertIn("feature.dart", violations[0])


if __name__ == "__main__":
    unittest.main()
