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
import test_bughouse_engine  # noqa: E402
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


class BughouseLockTest(unittest.TestCase):
    """The app's bughouse engine is HypeBeast, pinned per platform; Hivemind
    is pinned for the tools only and never fetched by default."""

    def setUp(self):
        self.lock = json.loads((ROOT / 'tools/assets.lock.json').read_text())

    def test_every_platform_pins_the_release_binary_it_unpacks(self):
        for name, spec in fetch_assets.BUGHOUSE_TARGETS.items():
            with self.subTest(name=name):
                entry = self.lock[name]
                self.assertEqual(entry['url'], f'{fetch_assets.HYPEBEAST_BASE}/{spec["asset"]}')
                self.assertRegex(entry['payload_sha256'], r'^[0-9a-f]{64}$')
                # A bare binary: what is downloaded is what the app unpacks.
                self.assertEqual(entry['source_sha256'], entry['payload_sha256'])
                self.assertNotIn('output_sha256', entry)

    def test_the_network_keeps_the_name_fairy_stockfish_matches_it_by(self):
        net = fetch_assets.BUGHOUSE_NETWORK
        self.assertEqual(self.lock[net['key']]['payload_sha256'], net['sha256'])
        self.assertTrue(net['name'].startswith('bughouse-'))
        self.assertEqual(net['name'], f'bughouse-{net["sha256"][:12]}.nnue')
        self.assertEqual(fetch_assets.manifest_key(net['dest']), net['name'])

    def test_hivemind_is_fetched_only_when_named_and_never_into_the_bundle(self):
        self.assertFalse(any(n.startswith('hivemind') for n in fetch_assets.resolve_targets(None)))
        self.assertEqual(fetch_assets.resolve_targets(['hivemind']),
                         [fetch_assets.hivemind_host_target()])
        for spec in fetch_assets.HIVEMIND_TARGETS.values():
            for _member, dest in (spec['engine'], spec['runtime']):
                self.assertTrue(dest.startswith('tools/hivemind-engine/'), dest)
        for name in fetch_assets.HIVEMIND_TARGETS:
            self.assertIn(f'{name}:engine', self.lock)
            self.assertIn(f'{name}:runtime', self.lock)
        self.assertIn('hivemind-network', self.lock)


DRIVE_PAGE = """<!DOCTYPE html><html><head><title>Google Drive - Virus scan warning</title></head>
<body><form id="download-form" action="https://drive.usercontent.google.com/download" method="get">
<input type="submit" id="uc-download-link" value="Download anyway"/>
<input type="hidden" name="id" value="FILEID"><input type="hidden" name="export" value="download">
<input type="hidden" name="confirm" value="t"><input type="hidden" name="uuid" value="a&amp;b"></form>
</body></html>"""


class BughouseFetchTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.assets = self.root / 'assets/bughouse'
        self.assets.mkdir(parents=True)
        for name, value in (('REPO_ROOT', self.root), ('BUGHOUSE_ASSETS', self.assets),
                            ('BUGHOUSE_MANIFEST', self.assets / 'manifest.json')):
            patcher = mock.patch.object(fetch_assets, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.engine = b'\x7fELF hypebeast' * 100
        self.net = b'NNUE bytes' * 100
        net = fetch_assets.BUGHOUSE_NETWORK
        self.lock = {
            'bughouse-linux': {'payload_sha256': hashlib.sha256(self.engine).hexdigest(),
                               'uncompressed_bytes': len(self.engine)},
            net['key']: {'payload_sha256': hashlib.sha256(self.net).hexdigest(),
                         'uncompressed_bytes': len(self.net)},
        }

    def install(self):
        fetch_assets.write_gz(self.engine, self.assets / 'hypebeast-linux.gz')
        fetch_assets.write_gz(self.net, self.root / fetch_assets.BUGHOUSE_NETWORK['dest'])
        fetch_assets.write_manifest({
            'hypebeast-linux': fetch_assets.manifest_entry(
                len(self.engine), hashlib.sha256(self.engine).hexdigest()),
            fetch_assets.BUGHOUSE_NETWORK['name']: fetch_assets.manifest_entry(
                len(self.net), hashlib.sha256(self.net).hexdigest()),
        })

    def problems(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return fetch_assets.check_bughouse(['bughouse-linux'], self.lock)

    def test_the_drive_warning_page_leads_to_the_download(self):
        url = fetch_assets._drive_confirm_url(DRIVE_PAGE)
        self.assertEqual(url, 'https://drive.usercontent.google.com/download'
                              '?id=FILEID&export=download&confirm=t&uuid=a%26b')
        self.assertIsNone(fetch_assets._drive_confirm_url('<html>quota exceeded</html>'))

    def test_a_good_install_passes_and_a_wrong_manifest_does_not(self):
        self.install()
        self.assertEqual(self.problems(), [])
        manifest = json.loads((self.assets / 'manifest.json').read_text())
        manifest['hypebeast-linux']['bytes'] += 1
        (self.assets / 'manifest.json').write_text(json.dumps(manifest))
        self.assertEqual(self.problems(), ['manifest'])

    def test_old_hivemind_files_fail_the_check_until_a_fetch_removes_them(self):
        self.install()
        kept = self.assets / 'notes.gz'
        kept.write_bytes(b'not ours')
        (self.assets / 'hivemind.onnx.gz').write_bytes(b'old')
        self.assertEqual(self.problems(), ['hivemind.onnx.gz'])
        with contextlib.redirect_stdout(io.StringIO()):
            fetch_assets.remove_stale_bughouse()
        self.assertEqual(self.problems(), [])
        self.assertTrue(kept.exists(), 'only the known Hivemind names are removed')

    def test_a_worktree_link_is_replaced_never_written_through(self):
        main = self.root / 'main'
        main.mkdir()
        (main / 'manifest.json').write_text('{"hivemind.onnx": {"bytes": 1, "sha256": "x"}}')
        (main / 'hivemind-linux.gz').write_bytes(b'main checkout engine')
        (self.assets / 'manifest.json').symlink_to(main / 'manifest.json')
        (self.assets / 'hivemind-linux.gz').symlink_to(main / 'hivemind-linux.gz')
        with contextlib.redirect_stdout(io.StringIO()):
            fetch_assets.remove_stale_bughouse()
        self.install()
        self.assertFalse((self.assets / 'manifest.json').is_symlink())
        self.assertFalse((self.assets / 'hivemind-linux.gz').exists())
        self.assertEqual((main / 'hivemind-linux.gz').read_bytes(), b'main checkout engine')
        self.assertIn('hivemind.onnx', (main / 'manifest.json').read_text())
        self.assertEqual(set(json.loads((self.assets / 'manifest.json').read_text())),
                         {'hypebeast-linux', fetch_assets.BUGHOUSE_NETWORK['name']})


    def test_a_write_uses_its_own_temporary_name_and_sweeps_stale_ones(self):
        dest = self.assets / 'hypebeast-linux.gz'
        stale = self.assets / '.hypebeast-linux.gz.dead1234.tmp'
        old_fixed = self.assets / 'hypebeast-linux.gz.tmp'
        fresh = self.assets / '.hypebeast-linux.gz.alive567.tmp'
        for path in (stale, old_fixed, fresh):
            path.write_bytes(b'partial')
        hour_ago = fetch_assets.time.time() - fetch_assets.STALE_TEMP_SECONDS - 5
        os.utime(stale, (hour_ago, hour_ago))
        os.utime(old_fixed, (hour_ago, hour_ago))
        fetch_assets.write_replacing(dest, b'engine')
        self.assertEqual(dest.read_bytes(), b'engine')
        self.assertFalse(stale.exists())
        self.assertFalse(old_fixed.exists())
        self.assertTrue(fresh.exists(), 'another fetch may still be writing it')

    def test_a_failed_write_leaves_no_temporary_file(self):
        dest = self.assets / 'hypebeast-linux.gz'
        with mock.patch.object(Path, 'replace', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                fetch_assets.write_replacing(dest, b'engine')
        self.assertEqual(list(self.assets.glob('*.tmp')) + list(self.assets.glob('.*.tmp')), [])

    def test_a_bad_mirror_listing_is_a_download_failure_not_a_traceback(self):
        name = fetch_assets.BUGHOUSE_NETWORK['name']
        good = {'name': name, 'chunks': [{'file': 'net-0.bin', 'sha256': 'a' * 64}]}
        self.assertEqual(fetch_assets.read_mirror_listing(json.dumps(good).encode(), 'b/'),
                         [('net-0.bin', 'a' * 64)])
        for raw in (b'\xff\xfe', b'[1, 2]', b'{"name": "x"}',
                    json.dumps({'name': 'other.nnue', 'chunks': []}).encode(),
                    json.dumps({'name': name, 'chunks': ['net-0.bin']}).encode(),
                    json.dumps({'name': name, 'chunks': [{'file': '../x', 'sha256': 'a' * 64}]}).encode(),
                    json.dumps({'name': name, 'chunks': [{'file': 'n.bin', 'sha256': 7}]}).encode(),
                    json.dumps({'name': name, 'chunks': []}).encode()):
            with self.subTest(raw=raw):
                with self.assertRaises(fetch_assets.DownloadError):
                    fetch_assets.read_mirror_listing(raw, 'b/')

    def test_mirror_parts_that_are_not_gzip_are_a_download_failure(self):
        name = fetch_assets.BUGHOUSE_NETWORK['name']
        part = b'not gzip at all'
        listing = json.dumps({'name': name, 'chunks': [
            {'file': 'net-0.bin', 'sha256': hashlib.sha256(part).hexdigest()}]}).encode()

        def stream(url, dest):
            dest.write_bytes(listing if url.endswith('net.json') else part)
            return 'application/octet-stream'

        with mock.patch.object(fetch_assets, '_stream', stream), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(fetch_assets.DownloadError):
                fetch_assets.download_from_mirror('b/', self.root / 'net', self.root)


class BughouseDepsTest(unittest.TestCase):
    """`deps` proves a binary or fails: one it could not check is no proof."""

    def deps(self, notes, all_=False):
        def audit(name):
            note = notes[name]
            if isinstance(note, Exception):
                raise note
            return note
        args = mock.Mock(all=all_)
        with mock.patch.object(test_bughouse_engine, 'audit_target', audit), \
                mock.patch.object(test_bughouse_engine, 'host_target', lambda: 'bughouse-macos-x86_64'), \
                mock.patch.object(test_bughouse_engine, 'TARGETS', {n: {} for n in notes}), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return test_bughouse_engine.cmd_deps(args)

    def test_the_host_platform_must_be_checked(self):
        self.assertEqual(self.deps({'bughouse-macos-x86_64': ['x86_64: links only /usr/lib/libSystem.B.dylib']}), 0)
        # The other architecture's build, or nothing fetched: not proven.
        self.assertEqual(self.deps({'bughouse-macos-x86_64': [
            'skipped: assets/bughouse/hypebeast-macos.gz holds the bughouse-macos-arm64 build']}), 1)
        self.assertEqual(self.deps({'bughouse-macos-x86_64': [
            'skipped: assets/bughouse/hypebeast-macos.gz not fetched']}), 1)

    def test_all_passes_over_platforms_not_fetched_but_needs_one(self):
        self.assertEqual(self.deps({'bughouse-linux': ['static: no loader, no shared libraries'],
                                    'bughouse-windows': ['skipped: not fetched']}, all_=True), 0)
        self.assertEqual(self.deps({'bughouse-linux': ['skipped: not fetched']}, all_=True), 1)
        self.assertEqual(self.deps({'bughouse-linux': test_bughouse_engine.Failure('dynamic')},
                                   all_=True), 1)


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
