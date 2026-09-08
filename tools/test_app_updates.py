#!/usr/bin/env python3
"""Exercise the shipped helpers with disposable fake bundles, never real installs."""
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import subprocess
import tempfile
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'linux', 'Linux helper')
class LinuxUpdateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='updater space-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.app = self.root / "Chess app 'quoted'"
        self.app.mkdir()
        (self.app / '.chess-auto-prep-portable').write_text('1\n')
        (self.app / 'chess_auto_prep').write_text('old executable')
        (self.app / 'personal.pgn').write_text('user annotation')
        self.state = self.root / 'updates' / 'attempt'
        self.state.mkdir(parents=True)
        self.armed = self.state / 'install-requested'
        self.armed.write_text('1')
        self.archive = self.state / 'linux.zip'

    def bundle(self, extra=None):
        with zipfile.ZipFile(self.archive, 'w') as archive:
            files = {
                'chess_auto_prep': '#!/bin/sh\nprintf restarted > "$(dirname "$0")/restarted"\n',
                'lib/libapp.so': 'library', 'data/icudtl.dat': 'icu',
                '.chess-auto-prep-portable': '1\n',
            }
            if extra:
                files.update(extra)
            for name, content in files.items():
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o755) << 16
                archive.writestr(info, content)

    def launch(self, app_pid='2147483647', digest=None, env=None):
        return subprocess.Popen([
            'bash', str(ROOT / 'assets/updater/install_linux.sh'), str(app_pid),
            str(self.archive), digest or hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            str(self.app / 'chess_auto_prep'), 'linuxPortable', str(self.armed),
        ], env=env)

    def wait_file(self, path):
        for _ in range(100):
            if path.exists():
                return
            time.sleep(.05)
        self.fail(f'Timed out waiting for {path}')

    def test_replace_and_restart_retains_old_bundle_and_user_files(self):
        self.bundle()
        with self.launch() as helper:
            self.assertEqual(helper.wait(timeout=10), 0)
        self.wait_file(self.app / 'restarted')
        self.assertEqual((self.app / 'personal.pgn').read_text(), 'user annotation')
        old = list(self.root.glob("Chess app*.previous-*"))
        self.assertEqual(len(old), 1)
        self.assertEqual((old[0] / 'personal.pgn').read_text(), 'user annotation')
        self.assertEqual((old[0] / 'chess_auto_prep').read_text(), 'old executable')

    def test_waits_for_close_and_cancellation_does_not_replace(self):
        self.bundle()
        with subprocess.Popen(['sleep', '10']) as app:
            try:
                with self.launch(app.pid) as helper:
                    self.wait_file(self.state / 'helper-ready')
                    self.assertEqual((self.app / 'chess_auto_prep').read_text(), 'old executable')
                    self.armed.unlink()
                    self.assertEqual(helper.wait(timeout=5), 0)
            finally:
                app.terminate()
                app.wait()
        self.assertEqual((self.app / 'personal.pgn').read_text(), 'user annotation')

    def test_corruption_rejected_before_any_replacement(self):
        self.bundle()
        with self.launch(digest='0' * 64) as helper:
            self.assertNotEqual(helper.wait(timeout=10), 0)
        self.assertEqual((self.app / 'chess_auto_prep').read_text(), 'old executable')

    def test_traversal_rejected(self):
        self.bundle({'../escape': 'bad'})
        with self.launch() as helper:
            self.assertNotEqual(helper.wait(timeout=10), 0)
        self.assertFalse((self.root / 'escape').exists())
        self.assertEqual((self.app / 'chess_auto_prep').read_text(), 'old executable')

    def test_archive_symlinks_are_rejected(self):
        self.bundle()
        with zipfile.ZipFile(self.archive, 'a') as archive:
            info = zipfile.ZipInfo('data/escape-link')
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, '../../outside')
        with self.launch() as helper:
            self.assertNotEqual(helper.wait(timeout=10), 0)
        self.assertEqual((self.app / 'chess_auto_prep').read_text(), 'old executable')

    def test_failed_swap_restores_old_install(self):
        self.bundle()
        commands = self.root / 'commands'
        commands.mkdir()
        # Fail only the stage-to-install rename, allow the restore rename.
        mv = commands / 'mv'
        mv.write_text('#!/bin/bash\ncase "$2" in *.update-*) exit 1;; esac\nexec /bin/mv "$@"\n')
        mv.chmod(0o755)
        with self.launch(env={**os.environ, 'PATH': f'{commands}:{os.environ["PATH"]}'}) as helper:
            self.assertNotEqual(helper.wait(timeout=10), 0)
        self.assertEqual((self.app / 'chess_auto_prep').read_text(), 'old executable')


@unittest.skipUnless(os.name == 'nt', 'Windows helper')
class WindowsUpdateTest(unittest.TestCase):
    def test_native_helper_verifies_then_launches_setup_and_restarts(self):
        with tempfile.TemporaryDirectory(prefix='updater space-') as tmp:
            root = Path(tmp)
            state = root / 'updates' / 'attempt'
            state.mkdir(parents=True)
            payload = state / 'setup.cmd'
            payload.write_text('@echo off\r\necho %* > "%~dp0arguments.txt"\r\nexit /b 0\r\n')
            app = root / 'app.cmd'
            app.write_text('@echo off\r\necho restarted > "%~dp0restarted.txt"\r\n')
            armed = state / 'install-requested'
            armed.write_text('1')
            request = state / 'request.json'
            request.write_text(json.dumps(dict(processId=2147483647, payload=str(payload),
                sha256=hashlib.sha256(payload.read_bytes()).hexdigest(), executable=str(app), armed=str(armed))))
            subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                str(ROOT / 'assets/updater/install_windows.ps1'), '-Request', str(request)], check=True, timeout=30)
            args = (state / 'arguments.txt').read_text()
            self.assertIn('/NOCLOSEAPPLICATIONS', args)
            self.assertIn('/NORESTART', args)
            for _ in range(100):
                if (root / 'restarted.txt').exists():
                    break
                time.sleep(.05)
            self.assertTrue((root / 'restarted.txt').exists())


if __name__ == '__main__':
    unittest.main()
