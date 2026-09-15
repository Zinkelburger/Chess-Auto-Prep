#!/usr/bin/env python3
"""Host-independent checks for the Windows binary/source and upgrade contract."""
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bughouse_windows
import fetch_assets
from test_bughouse_engine import pe_imports


class WindowsOrtBundleTest(unittest.TestCase):
    def test_shipped_engine_has_no_implicit_onnx_import(self):
        engine = bughouse_windows.verified_engine()
        imports = [name.lower() for name in pe_imports(engine)]
        self.assertNotIn("onnxruntime.dll", imports)
        self.assertNotIn("hivemind_ort.dll", imports)
        self.assertEqual(hashlib.sha256(engine).hexdigest(),
                         fetch_assets.load_lock()["bughouse-windows:engine"]["payload_sha256"])
        self.assertIn(hashlib.sha256(engine).hexdigest(),
                      (fetch_assets.REPO_ROOT / "tools/diagnose_bughouse_windows.ps1").read_text())

    def test_editing_loader_requires_rebuilding_binary(self):
        with tempfile.TemporaryDirectory() as td:
            copy = Path(td)
            for file in bughouse_windows.HERE.iterdir():
                if file.is_file():
                    shutil.copyfile(file, copy / file.name)
            with (copy / "ort_loader.h").open("a") as fh:
                fh.write("\n// changed after compilation\n")
            with patch.object(bughouse_windows, "HERE", copy):
                with self.assertRaisesRegex(ValueError, "ort_loader.h"):
                    bughouse_windows.verified_engine()

    def test_fetch_replaces_old_engine_even_when_old_lock_matches_cache(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            assets = root / "assets/bughouse"
            assets.mkdir(parents=True)
            old = b"previous release executable"
            # The release archive still contains the old executable; fetching
            # must install our rebuilt executable and retain the runtime bytes.
            runtime = b"pinned runtime payload"
            lock = {
                "bughouse-windows:engine": {"payload_sha256": hashlib.sha256(old).hexdigest()},
                "bughouse-windows:runtime": {},
            }
            fetch_assets.write_gz(old, assets / "hivemind-windows.exe.gz")
            fetch_assets.write_gz(runtime, assets / "hivemind_ort.dll.gz")

            def download(url, target, release_page):
                import zipfile
                with zipfile.ZipFile(target, "w") as archive:
                    archive.writestr("hivemind.exe", old)
                    archive.writestr("onnxruntime.dll", runtime)

            with patch.multiple(fetch_assets, REPO_ROOT=root, BUGHOUSE_ASSETS=assets,
                                BUGHOUSE_MANIFEST=assets / "manifest.json"), patch.object(fetch_assets, "download", download):
                fetch_assets.fetch_bughouse("bughouse-windows", lock, False)
            installed = gzip.decompress((assets / "hivemind-windows.exe.gz").read_bytes())
            self.assertEqual(installed, bughouse_windows.verified_engine())
            manifest = json.loads((assets / "manifest.json").read_text())
            self.assertIn("hivemind_ort.dll", manifest)
            self.assertNotIn("onnxruntime.dll", manifest)
            self.assertTrue((assets / "hivemind-windows-source.tar.gz").is_file())


if __name__ == "__main__":
    unittest.main()
