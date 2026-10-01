#!/usr/bin/env python3
"""Exercise release gates against disposable repositories and artifact sets."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import dart_checks
import release_assets


class AssetsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'artifacts'
        self.destination = self.root / 'public'
        self.files = []
        for directory, names in release_assets.expected_assets('v1.2.3').items():
            (self.source / directory).mkdir(parents=True)
            for name in names:
                file = self.source / directory / name
                file.write_bytes(name.encode())
                self.files.append(file)

    def stage(self):
        release_assets.stage('v1.2.3', self.source, self.destination)

    def test_complete_downloads_and_exact_checksums(self):
        self.stage()
        self.assertEqual(len(list(self.destination.iterdir())), 10)
        lines = (self.destination / 'SHA256SUMS').read_text().splitlines()
        self.assertEqual(len(lines), 9)
        for line in lines:
            digest, name = line.split('  ')
            self.assertEqual(digest, hashlib.sha256((self.destination / name).read_bytes()).hexdigest())

    def test_missing_empty_extra_and_symlink_downloads_are_rejected(self):
        for mutation in ('missing', 'empty', 'extra', 'symlink'):
            with self.subTest(mutation=mutation):
                file = self.files[0]
                original = file.read_bytes()
                extra = file.parent / 'desktop-release.json'
                if mutation == 'missing':
                    file.unlink()
                elif mutation == 'empty':
                    file.write_bytes(b'')
                elif mutation == 'extra':
                    extra.write_text('{}')
                else:
                    file.unlink()
                    file.symlink_to(self.files[1])
                with self.assertRaises(ValueError):
                    self.stage()
                self.assertFalse(self.destination.exists())
                if file.is_symlink():
                    file.unlink()
                file.write_bytes(original)
                extra.unlink(missing_ok=True)

    def test_diagnostics_artifact_is_rejected(self):
        (self.source / 'desktop-report').mkdir()
        with self.assertRaises(ValueError):
            self.stage()

    def test_wrong_tag_and_stale_destination_are_rejected(self):
        with self.assertRaises(ValueError):
            release_assets.stage('v1.2.4', self.source, self.destination)
        self.destination.mkdir()
        (self.destination / 'old.zip').write_text('old')
        with self.assertRaises(FileExistsError):
            self.stage()


class DartGatesTest(unittest.TestCase):
    def setUp(self):
        self.previous = Path.cwd()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(os.chdir, self.previous)
        self.root = Path(self.temp.name)
        os.chdir(self.root)
        self.addCleanup(patch.stopall)
        patch.object(dart_checks, 'ROOT', self.root).start()
        patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(self.root / 'build/job-summary.md')}).start()
        (self.root / '.fvmrc').write_text('{"flutter":"3.47.5"}')
        (self.root / '.gitignore').write_text('build/\n')
        (self.root / 'sample.dart').write_text('unformatted sentinel')
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        stub = '''import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
with open('build/trace.log', 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args == ['--version', '--machine']:
    print(json.dumps({'frameworkVersion': os.environ.get('TEST_SDK', '3.47.5')}))
elif args[0] == 'format':
    if '--output=none' not in args:
        pathlib.Path('sample.dart').write_text('mutated')
    print('format diagnostics')
    sys.exit(int(os.environ.get('TEST_FORMAT_EXIT', '0')))
elif args[0] == 'test' and os.environ.get('TEST_MUTATION'):
    pathlib.Path('sample.dart').write_text('changed during tests')
elif args[0] == 'test' and os.environ.get('TEST_COMMIT'):
    subprocess.run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
                    'commit', '--allow-empty', '-qm', 'changed HEAD'], check=True)
'''
        for name in ('flutter', 'dart'):
            exe = bin_dir / name
            exe.write_text(f'#!{sys.executable}\n{stub}')
            exe.chmod(0o755)
        self.flutter = str(bin_dir / 'flutter')
        for args in (['init', '-q'], ['add', '.'],
                     ['-c', 'user.name=Test', '-c', 'user.email=test@example.com',
                      'commit', '-qm', 'fixture']):
            subprocess.run(['git', *args], check=True, capture_output=True)

    def run_gate(self, gate='preflight', extra=()):
        return dart_checks.run(gate, self.flutter, extra)

    def trace(self):
        return [json.loads(line) for line in (self.root / 'build/trace.log').read_text().splitlines()]

    def test_preflight_validates_committed_head(self):
        self.assertEqual(self.run_gate(), 0)
        self.assertEqual([args[0] for args in self.trace()], ['--version', 'pub', 'format', 'analyze', 'test'])
        summary = (self.root / 'build/quality-gates/summary.md').read_text()
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
        self.assertIn(head, summary)
        self.assertIn('HEAD unchanged', summary)

    def test_format_failure_does_not_mutate_and_preserves_first_failure(self):
        with patch.dict(os.environ, {'TEST_FORMAT_EXIT': '1'}):
            self.assertEqual(self.run_gate(), 1)
        self.assertEqual((self.root / 'sample.dart').read_text(), 'unformatted sentinel')
        self.assertEqual(self.trace()[-1][0], 'format')
        self.assertIn('format diagnostics', (self.root / 'build/quality-gates/format.log').read_text())
        self.assertIn('First failed gate: format', (self.root / 'build/job-summary.md').read_text())

    def test_sdk_mismatch_stops_before_format(self):
        with patch.dict(os.environ, {'TEST_SDK': '3.47.2'}):
            self.assertEqual(self.run_gate(), 1)
        self.assertEqual(len(self.trace()), 1)

    def test_dirty_tracked_or_untracked_checkout_stops_before_sdk(self):
        for file in ('sample.dart', 'untracked.txt'):
            with self.subTest(file=file):
                subprocess.run(['git', 'checkout', '--', 'sample.dart'], check=True)
                (self.root / file).write_text('dirty')
                self.assertEqual(self.run_gate(), 1)
                self.assertFalse((self.root / 'build/trace.log').exists())

    def test_mutation_during_checks_is_a_failure(self):
        with patch.dict(os.environ, {'TEST_MUTATION': '1'}):
            self.assertEqual(self.run_gate(), 1)
        self.assertIn('First failed gate: checkout', (self.root / 'build/quality-gates/failure.log').read_text())

    def test_head_change_during_checks_is_a_failure_even_when_clean(self):
        with patch.dict(os.environ, {'TEST_COMMIT': '1'}):
            self.assertEqual(self.run_gate(), 1)
        self.assertIn('HEAD changed during preflight', (self.root / 'build/quality-gates/failure.log').read_text())

    def test_focused_test_arguments_are_forwarded(self):
        self.assertEqual(self.run_gate('test', ['test/example_test.dart', '--plain-name', 'a test']), 0)
        self.assertEqual(self.trace()[-1][-3:], ['test/example_test.dart', '--plain-name', 'a test'])


if __name__ == '__main__':
    unittest.main()
