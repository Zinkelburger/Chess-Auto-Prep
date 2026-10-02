#!/usr/bin/env python3
"""The Stockfish pins hold on any machine: the engine is what is checked,
never the gzip container, whose bytes depend on the local zlib."""
import contextlib
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import fetch_assets  # noqa: E402
import package_macos_stockfish  # noqa: E402

ENGINE = b'\x7fELF stockfish' * 1000


def packed(level):
    """The same engine packed the way another machine's zlib might."""
    return gzip.compress(ENGINE, compresslevel=level, mtime=0)


def mac_engine(arm=1024, pointer=1056, network=b'pinned NNUE network'):
    """Tiny Mach-O with the same cross-slice offset contract as Stockfish 19."""
    data = bytearray(arm + 128)
    struct.pack_into('>II', data, 0, 0xCAFEBABE, 2)
    struct.pack_into('>5I', data, 8, 0x01000007, 3, 64, 768, 6)
    struct.pack_into('>5I', data, 28, 0x0100000C, 0, arm, 128, 6)
    struct.pack_into('<8I', data, 64, 0xFEEDFACF, 0x01000007, 3, 2, 2, 96, 0, 0)
    struct.pack_into('<II16s4Q4I', data, 96, 0x19, 72, b'__DATA',
                     0x1000, 768, 0, 768, 3, 3, 0, 0)
    names = b'\0_gUniversalNNUEOffset\0_gUniversalNNUESize\0'
    struct.pack_into('<6I', data, 168, 2, 24, 320, 2, 352, len(names))
    struct.pack_into('<2Q', data, 64 + 256, pointer, len(network))
    struct.pack_into('<IBBHQ', data, 64 + 320, 1, 0xF, 1, 0, 0x1100)
    struct.pack_into('<IBBHQ', data, 64 + 336, 23, 0xF, 1, 0, 0x1108)
    data[64 + 352:64 + 352 + len(names)] = names
    data[arm + 32:arm + 32 + len(network)] = network
    return bytes(data)


class MacLayoutTest(unittest.TestCase):
    def test_signer_relocation_rebases_the_network_pointer(self):
        original = mac_engine()
        signed = mac_engine(arm=4096)
        repaired = package_macos_stockfish.repair_network_offset(original, signed)
        self.assertEqual(repaired, mac_engine(arm=4096, pointer=4128))
        self.assertEqual(package_macos_stockfish.repair_network_offset(original, repaired), repaired)

    def test_network_corruption_and_truncation_are_rejected(self):
        for signed in (mac_engine(network=b'broken NNUE network'), mac_engine()[:-16]):
            with self.subTest(signed=signed[-25:]), self.assertRaises(RuntimeError):
                package_macos_stockfish.repair_network_offset(mac_engine(), signed)


class LockTest(unittest.TestCase):
    """Every Stockfish entry in the committed lock pins its engine."""

    def test_every_stockfish_entry_pins_the_engine_not_the_container(self):
        lock = json.loads((ROOT / 'tools/assets.lock.json').read_text())
        for name in fetch_assets.STOCKFISH_TARGETS:
            with self.subTest(name=name):
                entry = lock[name]
                self.assertRegex(entry['payload_sha256'], r'^[0-9a-f]{64}$')
                self.assertNotIn('output_sha256', entry)

    def test_both_macos_entries_pin_the_one_universal_binary(self):
        lock = json.loads((ROOT / 'tools/assets.lock.json').read_text())
        self.assertEqual(lock['stockfish-macos-arm64']['payload_sha256'],
                         lock['stockfish-macos-x86_64']['payload_sha256'])


class FetcherTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.dest = self.root / 'assets/executables/stockfish-linux.gz'
        self.dest.parent.mkdir(parents=True)
        patcher = mock.patch.object(fetch_assets, 'REPO_ROOT', self.root)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.lock = {'stockfish-linux': {
            'payload_sha256': hashlib.sha256(ENGINE).hexdigest()}}

    def current(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return fetch_assets.dest_is_current('stockfish-linux', self.dest, self.lock)

    def test_an_engine_packed_by_another_zlib_is_current(self):
        for level in (1, 6, 9):
            with self.subTest(level=level):
                self.dest.write_bytes(packed(level))
                self.assertTrue(self.current())

    def test_another_engine_or_a_broken_file_is_not(self):
        self.dest.write_bytes(gzip.compress(b'another engine', mtime=0))
        self.assertFalse(self.current())
        self.dest.write_bytes(b'not a gzip stream')
        self.assertFalse(self.current())
        self.dest.write_bytes(packed(9)[:-8])  # no CRC and size trailer
        self.assertFalse(self.current())

    def test_check_reports_a_wrong_engine(self):
        self.dest.write_bytes(gzip.compress(b'another engine', mtime=0))
        with contextlib.redirect_stdout(io.StringIO()):
            problems = fetch_assets.check_stockfish(['stockfish-linux'], self.lock)
        self.assertEqual(problems, ['stockfish-linux'])
        self.dest.write_bytes(packed(1))
        with contextlib.redirect_stdout(io.StringIO()):
            problems = fetch_assets.check_stockfish(['stockfish-linux'], self.lock)
        self.assertEqual(problems, [])


class MacPackagingTest(unittest.TestCase):
    """The Xcode build phase, with codesign stood in: only its check runs."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / 'tools').mkdir()
        (self.root / 'assets/executables').mkdir(parents=True)
        (self.root / 'tools/package_macos_stockfish.py').write_bytes(
            (ROOT / 'tools/package_macos_stockfish.py').read_bytes())
        self.engine = mac_engine()
        self.pinned = hashlib.sha256(self.engine).hexdigest()

    def build(self, archs, host, *, arm64_pin=None, x86_pin=None, repack=False, unstable=False):
        lock = {'stockfish-macos-arm64': {'payload_sha256': arm64_pin or self.pinned},
                'stockfish-macos-x86_64': {'payload_sha256': x86_pin or self.pinned}}
        (self.root / 'tools/assets.lock.json').write_text(json.dumps(lock))
        runner = self.root / 'run.py'
        runner.write_text(
            'import platform, runpy, subprocess, sys\n'
            f'platform.machine = lambda: {host!r}\n'
            'from pathlib import Path\n'
            'signs = 0\n'
            'def codesign(args, **kwargs):\n'
            '    global signs\n'
            '    if "--force" in args:\n'
            '        signs += 1\n'
            f'        if signs == 1 and {repack!r}:\n'
            f'            Path(args[-1]).write_bytes({mac_engine(arm=4096)!r})\n'
            f'        if signs == 2 and {unstable!r}:\n'
            f'            Path(args[-1]).write_bytes({mac_engine(arm=8192, pointer=4128)!r})\n'
            '    Path("sign-count").write_text(str(signs))\n'
            'subprocess.run = codesign\n'
            f'runpy.run_path({str(self.root / "tools/package_macos_stockfish.py")!r},'
            " run_name='__main__')\n")
        env = {**os.environ, 'TARGET_BUILD_DIR': str(self.root / 'out'),
               'CONTENTS_FOLDER_PATH': 'App.app/Contents'}
        env.pop('ARCHS', None)
        if archs is not None:
            env['ARCHS'] = archs
        return subprocess.run([sys.executable, str(runner)], env=env, cwd=self.root,
                              capture_output=True, text=True)

    def helper(self):
        return self.root / 'out/App.app/Contents/Helpers/stockfish-macos'

    def test_an_engine_packed_by_this_runners_zlib_is_accepted(self):
        (self.root / 'assets/executables/stockfish-macos.gz').write_bytes(gzip.compress(self.engine, compresslevel=1))
        result = self.build('x86_64', 'arm64')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.helper().read_bytes(), self.engine)

    def test_repacked_helper_is_repaired_and_signed_again(self):
        (self.root / 'assets/executables/stockfish-macos.gz').write_bytes(gzip.compress(self.engine))
        result = self.build('x86_64', 'x86_64', repack=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.helper().read_bytes(), mac_engine(arm=4096, pointer=4128))
        self.assertEqual((self.root / 'sign-count').read_text(), '2')

    def test_a_signer_that_keeps_moving_the_network_is_rejected(self):
        (self.root / 'assets/executables/stockfish-macos.gz').write_bytes(gzip.compress(self.engine))
        result = self.build('x86_64', 'x86_64', repack=True, unstable=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('did not stabilize', result.stderr)

    def test_the_built_architecture_decides_not_the_host(self):
        (self.root / 'assets/executables/stockfish-macos.gz').write_bytes(gzip.compress(self.engine, compresslevel=9))
        wrong = '0' * 64
        self.assertEqual(self.build('x86_64', 'arm64', arm64_pin=wrong).returncode, 0)
        self.assertNotEqual(self.build('arm64', 'arm64', arm64_pin=wrong).returncode, 0)
        self.assertNotEqual(self.build(None, 'arm64', arm64_pin=wrong).returncode, 0)

    def test_a_different_engine_is_refused(self):
        (self.root / 'assets/executables/stockfish-macos.gz').write_bytes(
            gzip.compress(b'another engine', mtime=0))
        result = self.build('arm64', 'arm64')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not match', result.stderr)
        self.assertFalse(self.helper().exists())


if __name__ == '__main__':
    unittest.main()
