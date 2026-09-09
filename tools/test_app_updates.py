#!/usr/bin/env python3
"""Exercise the shipped helpers with disposable fake bundles, never real installs."""
import hashlib
import json
import os
import shutil
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
    @classmethod
    def setUpClass(cls):
        tmp = tempfile.TemporaryDirectory(prefix='updater probe-')
        cls.addClassCleanup(tmp.cleanup)
        cls.probe = Path(tmp.name) / 'probe.exe'
        # Windows PowerShell uses the installed .NET Framework compiler. No
        # downloaded compiler, shell-script association or real installer.
        result = subprocess.run([
            'powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
            "$ErrorActionPreference = 'Stop'; "
            'Add-Type -Path $env:UPDATER_PROBE_SOURCE '
            '-OutputAssembly $env:UPDATER_PROBE_OUTPUT -OutputType ConsoleApplication',
        ], env={**os.environ,
                'UPDATER_PROBE_SOURCE': str(ROOT / 'tools/fixtures/updater_probe.cs'),
                'UPDATER_PROBE_OUTPUT': str(cls.probe)},
            capture_output=True, text=True, timeout=60)
        if result.returncode or not cls.probe.exists():
            raise AssertionError(f'Cannot compile updater probe: {result.stdout}\n{result.stderr}')

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="updater café 'quoted'-")
        self.addCleanup(self.cleanup_directory, tmp)
        self.root = Path(tmp.name)
        self.state = self.root / 'updates' / 'attempt'
        self.state.mkdir(parents=True)
        self.payload = self.state / 'setup.exe'
        shutil.copyfile(self.probe, self.payload)
        self.app = self.root / 'Chess app' / 'app.exe'
        self.app.parent.mkdir()
        shutil.copyfile(self.probe, self.app)
        self.armed = self.state / 'install-requested'
        self.armed.write_text('1')
        self.request = self.state / 'request.json'
        self.write_request()
        # Preserve logs before TemporaryDirectory cleanup, including on failure.
        self.addCleanup(self.preserve_diagnostics)

    @staticmethod
    def cleanup_directory(tmp):
        # The restarted native probe writes its marker immediately before
        # exiting. Windows can still hold app.exe open after we see that
        # marker; wait for the actual file release instead of racing rmtree.
        # Persistent permission failures still fail the test after a deadline.
        deadline = time.monotonic() + 15
        while True:
            try:
                tmp.cleanup()
                return
            except PermissionError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(.05)

    def write_request(self, process_id=2147483647, digest=None):
        self.request.write_text(json.dumps(dict(
            processId=process_id, payload=str(self.payload),
            sha256=digest or hashlib.sha256(self.payload.read_bytes()).hexdigest(),
            executable=str(self.app), armed=str(self.armed)), ensure_ascii=False), encoding='utf-8')

    def preserve_diagnostics(self):
        destination = os.environ.get('APP_UPDATE_TEST_ARTIFACTS')
        if destination:
            shutil.copytree(self.root / 'updates',
                            Path(destination) / self._testMethodName, dirs_exist_ok=True)

    def diagnostics(self):
        parts = []
        for path in sorted((self.root / 'updates').rglob('*')):
            if path.is_file() and path.suffix in ('.txt', '.log', '.json'):
                data = path.read_bytes()
                encoding = 'utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig'
                parts.append(f'{path.name}:\n{data.decode(encoding, errors="replace")}')
        return '\n'.join(parts)

    def launch(self, env=None):
        helper = subprocess.Popen([
            'powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy',
            'Bypass', '-File', str(ROOT / 'assets/updater/install_windows.ps1'),
            '-Request', str(self.request),
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.addCleanup(self.stop_process, helper)
        return helper

    @staticmethod
    def stop_process(process):
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=10)

    def finish(self, helper, expected_code=0):
        stdout, stderr = helper.communicate(timeout=30)
        (self.state / 'helper-output.txt').write_text(
            f'stdout:\n{stdout}\nstderr:\n{stderr}', encoding='utf-8')
        self.assertEqual(helper.returncode, expected_code, self.diagnostics())

    def wait_file(self, path, helper):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if path.exists():
                return
            if helper.poll() is not None and path.name == 'helper-ready':
                self.finish(helper)
                break
            time.sleep(.05)
        self.fail(f'Timed out waiting for {path}\n{self.diagnostics()}')

    def assert_not_installed(self):
        self.assertFalse((self.state / 'arguments.txt').exists(), self.diagnostics())
        self.assertFalse((self.app.parent / 'restarted.txt').exists(), self.diagnostics())

    def test_native_helper_verifies_then_launches_setup_and_restarts(self):
        helper = self.launch()
        self.finish(helper)
        arguments = self.state / 'arguments.txt'
        self.assertTrue(arguments.exists(), self.diagnostics())
        self.assertEqual(arguments.read_text(encoding='utf-8-sig').splitlines(), [
            '/SILENT', '/NORESTART', '/NOCLOSEAPPLICATIONS', '/NORESTARTAPPLICATIONS',
            f'/DIR={self.app.parent}', f'/LOG={self.state / "setup.log"}',
        ])
        self.wait_file(self.app.parent / 'restarted.txt', helper)
        self.assertFalse(self.armed.exists())
        self.assertFalse((self.state / 'helper-ready').exists())
        self.assertFalse((self.state.parent / 'last-error.txt').exists())

    def test_corruption_rejected_before_installer_launch(self):
        self.write_request(digest='0' * 64)
        self.finish(self.launch(), expected_code=1)
        self.assertIn('Update checksum mismatch', self.diagnostics())
        self.assert_not_installed()
        self.assertFalse(self.armed.exists())
        self.assertFalse((self.state / 'helper-ready').exists())

    def test_inherited_module_path_cannot_hide_windows_powershell_modules(self):
        # Like a pwsh -> Python -> powershell.exe launch, the helper starts
        # with a module path that does not resolve its host's built-in modules.
        # Do not sanitize this in the harness: production must handle it too.
        unrelated = self.root / 'unrelated modules'
        unrelated.mkdir()
        env = {k: v for k, v in os.environ.items() if k.upper() != 'PSMODULEPATH'}
        env['PSModulePath'] = str(unrelated)
        helper = self.launch(env=env)
        self.finish(helper)
        self.assertTrue((self.state / 'arguments.txt').exists(), self.diagnostics())
        self.wait_file(self.app.parent / 'restarted.txt', helper)

    def test_installer_failure_is_reported_without_restart(self):
        (self.state / 'setup-exit.txt').write_text('23')
        self.finish(self.launch(), expected_code=1)
        self.assertIn('Installer exited with 23', self.diagnostics())
        self.assertTrue((self.state / 'arguments.txt').exists(), self.diagnostics())
        self.assertFalse((self.app.parent / 'restarted.txt').exists())
        self.assertFalse(self.armed.exists())

    def test_cancelled_request_does_not_launch_installer(self):
        self.armed.unlink()
        self.finish(self.launch())
        self.assert_not_installed()
        self.assertFalse((self.state.parent / 'last-error.txt').exists())

    def test_waits_for_app_close_and_honors_cancellation(self):
        app = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
        self.addCleanup(self.stop_process, app)
        self.write_request(process_id=app.pid)
        helper = self.launch()
        self.wait_file(self.state / 'helper-ready', helper)
        self.assertIsNone(helper.poll())
        self.assert_not_installed()
        self.armed.unlink()
        self.finish(helper)
        self.assertIsNone(app.poll())
        self.assert_not_installed()


if __name__ == '__main__':
    unittest.main()
