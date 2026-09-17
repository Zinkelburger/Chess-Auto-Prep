#!/usr/bin/env python3
"""Offline tests for agent admission, isolation and cleanup; no Flutter jobs."""
import contextlib
import argparse
import importlib.util
import json
import multiprocessing as mp
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
import agent_job as jobs


def reserve(root, name, events, duration):
    leases = [jobs.Lease(Path(root) / f'slot-{i}.lock') for i in range(2)]
    try:
        while not any(lease.try_acquire() for lease in leases):
            time.sleep(0.01)
        events.put(('start', name, time.monotonic()))
        time.sleep(duration)
        events.put(('end', name, time.monotonic()))
    finally:
        for lease in leases:
            lease.close()


class JobTests(unittest.TestCase):
    def test_two_slots_admit_two_processes_and_queue_the_third(self):
        with tempfile.TemporaryDirectory() as directory:
            events = mp.Queue()
            children = [mp.Process(target=reserve, args=(directory, str(i), events, 0.25)) for i in range(3)]
            for child in children:
                child.start()
            timeline = [events.get(timeout=5) for _ in range(6)]
            for child in children:
                child.join(5)
                self.assertEqual(child.exitcode, 0)
            count = peak = 0
            for kind, _, _ in sorted(timeline, key=lambda event: event[2]):
                count += 1 if kind == 'start' else -1
                peak = max(peak, count)
            self.assertEqual(peak, 2)
            self.assertEqual(count, 0)
            events.close(); events.join_thread()

    def test_checkout_is_exclusive_and_old_lock_excludes_new_shared_jobs(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'checkout.lock'
            first = jobs.Lease(path); second = jobs.Lease(path, shared=True)
            try:
                self.assertTrue(first.try_acquire())
                self.assertFalse(second.try_acquire())
            finally:
                first.close()
            try:
                self.assertTrue(second.try_acquire())
                third = jobs.Lease(path, shared=True)
                try:
                    self.assertTrue(third.try_acquire())
                finally:
                    third.close()
            finally:
                second.close()

    def test_dead_worker_cannot_release_slot_while_its_children_survive(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'slot.lock'
            path.with_suffix('.json').write_text(json.dumps({'cgroup': '/previous.service'}))
            lease = jobs.Lease(path, {'cgroup': '/next.service'})
            try:
                with patch.object(jobs, 'populated', return_value=True):
                    self.assertFalse(lease.try_acquire())
                with patch.object(jobs, 'populated', return_value=False):
                    self.assertTrue(lease.try_acquire())
            finally:
                lease.close()

    def test_profiles_separate_documents_preferences_and_app_instances(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(jobs, 'STATE', Path(directory)):
            first = jobs.profile_env(Path(directory) / 'first')
            second = jobs.profile_env(Path(directory) / 'second')
            self.assertNotEqual(first['XDG_CONFIG_HOME'], second['XDG_CONFIG_HOME'])
            self.assertNotEqual(first['BUGHOUSE_DB_HOME'], second['BUGHOUSE_DB_HOME'])
            self.assertTrue(Path(first['BUGHOUSE_DB_HOME']).is_relative_to(first['XDG_DATA_HOME']))
            self.assertEqual(first.get('HOME'), os.environ.get('HOME'))
            self.assertEqual(first['CHESS_AUTO_PREP_NEW_INSTANCE'], '1')
            choice = Path(first['XDG_DATA_HOME']) / 'chess_auto_prep/desktop-integration-choice'
            self.assertEqual(choice.read_text(), 'no')
            choice.write_text('yes')
            jobs.profile_env(Path(directory) / 'first')
            self.assertEqual(choice.read_text(), 'yes')
            docs = subprocess.check_output(['xdg-user-dir', 'DOCUMENTS'], env=first, text=True).strip()
            self.assertTrue(docs.startswith(directory))
            self.assertTrue(Path(docs).is_dir())

    def test_missing_xvfb_fails_without_using_desktop(self):
        with patch.object(jobs, 'xvfb_binary', side_effect=RuntimeError('missing')):
            with self.assertRaisesRegex(RuntimeError, 'missing'):
                with jobs.display({'DISPLAY': ':0'}, True):
                    self.fail('must not fall back to real display')

    def test_headless_runtime_is_private_per_job_and_drops_desktop_bus(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(jobs, 'RUNTIME_ROOT', Path(directory)):
            original = {'XDG_RUNTIME_DIR': directory, 'DBUS_SESSION_BUS_ADDRESS': 'desktop-bus',
                        'DBUS_SESSION_BUS_PID': '1', 'DBUS_STARTER_ADDRESS': 'desktop-bus',
                        'DBUS_STARTER_BUS_TYPE': 'session', 'SESSION_MANAGER': 'desktop-session'}
            runtimes = []
            for name in ('chess-prep-job-first', 'chess-prep-job-second'):
                runtime = Path(directory) / name
                runtime.mkdir(mode=0o700)
                with patch.object(jobs, 'current_cgroup', return_value=f'/chessprep.slice/{name}.service'):
                    env = jobs.headless_env(original)
                self.assertEqual(env, {'XDG_RUNTIME_DIR': str(runtime)})
                runtimes.append(env['XDG_RUNTIME_DIR'])
            self.assertNotEqual(*runtimes)
            self.assertEqual(original['XDG_RUNTIME_DIR'], directory)
            self.assertEqual(original['DBUS_SESSION_BUS_ADDRESS'], 'desktop-bus')

    def test_missing_or_unsafe_runtime_never_falls_back_to_desktop(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(jobs, 'RUNTIME_ROOT', Path(directory)), \
                patch.object(jobs, 'current_cgroup', return_value='/chessprep.slice/chess-prep-job-test.service'):
            env = {'XDG_RUNTIME_DIR': directory}
            runtime = Path(directory) / 'chess-prep-job-test'
            with self.assertRaisesRegex(RuntimeError, 'missing'):
                jobs.headless_env(env)
            runtime.mkdir(mode=0o755)
            with self.assertRaisesRegex(RuntimeError, '0700'):
                jobs.headless_env(env)
            runtime.rmdir()
            runtime.symlink_to(directory, target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, '0700'):
                jobs.headless_env(env)

    def test_runtime_lifetime_is_owned_by_headless_service_only(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(jobs, 'STATE', Path(directory)), \
                patch.object(jobs, 'setup'), patch.object(jobs, 'xvfb_binary'), \
                patch.object(jobs.subprocess, 'run'), patch.object(jobs.subprocess, 'Popen') as spawn:
            spawn.return_value.poll.return_value = 0
            spawn.return_value.returncode = 0
            for headless in (False, True):
                self.assertEqual(jobs.run(argparse.Namespace(
                    headless=headless, wait_seconds=10, command=['true'])), 0)
                command = spawn.call_args.args[0]
                unit = command[command.index('--unit') + 1]
                self.assertEqual(f'RuntimeDirectory={unit}' in command, headless)
                self.assertEqual('RuntimeDirectoryMode=0700' in command, headless)
                self.assertIn('KillMode=control-group', command)

    def test_owner_exit_cancels_job(self):
        with patch.object(jobs, 'process_token', return_value='gone'):
            before = time.monotonic()
            with self.assertRaisesRegex(RuntimeError, 'exited'):
                jobs.run_child([sys.executable, '-c', 'import time; time.sleep(20)'], dict(os.environ), os.getpid(), 'original')
            self.assertLess(time.monotonic() - before, 3)

    def test_direct_worker_cannot_bypass_containment(self):
        import argparse
        with patch.object(jobs, 'current_cgroup', return_value='/some-editor.scope'):
            with self.assertRaisesRegex(RuntimeError, 'bounded systemd'):
                jobs.worker(argparse.Namespace())

    def test_headless_display_is_private_and_process_is_cleaned_up(self):
        try:
            jobs.xvfb_binary()
        except RuntimeError:
            self.skipTest('Xvfb not installed on this host')
        with tempfile.TemporaryDirectory() as directory, patch.object(jobs, 'STATE', Path(directory)):
            original = dict(os.environ)
            with jobs.display(jobs.profile_env(Path(directory)), True) as env:
                self.assertEqual(env['GDK_BACKEND'], 'x11')
                self.assertNotIn('WAYLAND_DISPLAY', env)
                self.assertNotEqual(env['DISPLAY'], original.get('DISPLAY'))
                socket = Path('/tmp/.X11-unix/X' + env['DISPLAY'][1:])
                self.assertTrue(socket.exists())
            self.assertFalse(socket.exists())
            self.assertEqual(dict(os.environ), original)


if __name__ == '__main__':
    unittest.main()
