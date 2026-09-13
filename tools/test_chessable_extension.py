#!/usr/bin/env python3
"""Checks for the Chessable → PGN browser extension in tools/chessable_extension.

Validates the manifest, then runs the Node test (pure PGN functions, plus the
DOM extraction in a headless Chrome when one is installed).

Usage:
    python3 tools/test_chessable_extension.py
"""

import json
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

EXT = Path(__file__).resolve().parent / "chessable_extension"


class ManifestTest(unittest.TestCase):
    def test_manifest_lists_existing_scripts(self):
        manifest = json.loads((EXT / "manifest.json").read_text())
        self.assertEqual(manifest["manifest_version"], 3)
        scripts = manifest["content_scripts"][0]["js"]
        self.assertEqual(scripts, ["chessable_pgn.js", "content.js"])
        for name in scripts:
            self.assertTrue((EXT / name).is_file(), name)
        self.assertIn("storage", manifest["permissions"])
        self.assertNotIn("background", manifest, "no background script is needed")

    def test_content_script_only_uses_the_pure_module_api(self):
        api = (EXT / "chessable_pgn.js").read_text()
        content = (EXT / "content.js").read_text()
        exported = api.split("const api = {", 1)[1].split("};", 1)[0]
        names = {line.strip().rstrip(",") for line in exported.splitlines() if line.strip()}
        import re

        for used in set(re.findall(r"\bP\.(\w+)", content)):
            self.assertIn(used, names, f"content.js uses P.{used} which is not exported")


class NodeTest(unittest.TestCase):
    def test_node_suite(self):
        node = shutil.which("node")
        if not node:
            self.skipTest("node is not installed")
        result = subprocess.run(
            [node, str(EXT / "test_pgn.js")],
            capture_output=True,
            text=True,
            timeout=180,
        )
        sys.stdout.write(result.stdout)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
