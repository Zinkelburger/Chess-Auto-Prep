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
        with tempfile.TemporaryDirectory() as directory, patch.object(jobs, 'storage_dir', return_value=Path(directory)):
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

    def test_a_job_temp_folder_holds_everything_and_goes_with_the_job(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(jobs, 'storage_dir', return_value=Path(directory)), \
                patch.object(jobs, 'STATE', Path(directory) / 'locks'):
            with jobs.job_temp({'KEEP': '1'}) as env:
                temp = Path(env['TMPDIR'])
                self.assertEqual(env['KEEP'], '1')
                self.assertEqual(env['TMP'], env['TMPDIR'])
                self.assertEqual(env['TEMP'], env['TMPDIR'])
                self.assertTrue(temp.is_relative_to(directory))
                made = subprocess.check_output(
                    [sys.executable, '-c', 'import tempfile; print(tempfile.mkdtemp())'],
                    env=dict(os.environ, **env), text=True).strip()
                self.assertTrue(Path(made).is_relative_to(temp))
                locked = temp / 'locked'
                locked.mkdir()
                (locked / 'file').write_text('x')
                locked.chmod(0o500)
            self.assertFalse(temp.exists())

    def test_a_killed_jobs_temp_folder_is_swept_and_a_running_one_kept(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(jobs, 'storage_dir', return_value=Path(directory)), \
                patch.object(jobs, 'STATE', Path(directory) / 'locks'):
            dead = Path(directory) / f'{jobs.JOB_TEMP_PREFIX}2147483646-1-abc'
            (dead / 'leftover').mkdir(parents=True)
            alive = Path(directory) / (f'{jobs.JOB_TEMP_PREFIX}{os.getpid()}-'
                                       f'{jobs.process_token(os.getpid())}-abc')
            alive.mkdir()
            other = Path(directory) / 'slot-0.lock'
            other.write_text('')
            jobs.sweep_job_temps()
            self.assertFalse(dead.exists())
            self.assertTrue(alive.exists())
            self.assertTrue(other.exists())

    def test_sweeper_keeps_live_service_children_and_legacy_locks(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(jobs, 'storage_dir', return_value=Path(directory) / 'cache'), \
                patch.object(jobs, 'STATE', Path(directory) / 'locks'), \
                patch.object(jobs, 'populated', return_value=True) as populated:
            legacy = jobs.STATE / f'{jobs.JOB_TEMP_PREFIX}2147483646-1-old'
            legacy.mkdir(parents=True)
            slot = jobs.STATE / 'slot-0.json'
            slot.write_text(json.dumps({'pid': 2147483646, 'cgroup': '/old.service'}))
            lock = jobs.STATE / 'slot-0.lock'
            lock.touch()
            current = Path(directory) / 'cache' / f'{jobs.JOB_TEMP_PREFIX}2147483645-1-new'
            current.mkdir(parents=True)
            (current / '.owner.json').write_text(json.dumps({'cgroup': '/new.service'}))
            alias = current.parent / f'{jobs.JOB_TEMP_PREFIX}2147483644-1-alias'
            alias.symlink_to(legacy, target_is_directory=True)
            jobs.sweep_job_temps()
            self.assertTrue(legacy.exists())
            self.assertTrue(current.exists())
            populated.return_value = False
            jobs.sweep_job_temps()
            self.assertFalse(legacy.exists())
            self.assertFalse(current.exists())
            self.assertTrue(alias.is_symlink())
            self.assertTrue(lock.exists())
            self.assertTrue(slot.exists())

    def test_cache_must_be_private_owned_disk_storage(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {'CHESS_PREP_JOB_CACHE': directory}), \
                patch.object(jobs, 'require_disk_storage') as require_disk:
            self.assertEqual(jobs.storage_dir(), Path(directory))
            require_disk.assert_called_once_with(Path(directory))
            Path(directory).chmod(0o755)
            with self.assertRaisesRegex(RuntimeError, '0700'):
                jobs.storage_dir()
            Path(directory).chmod(0o700)
            alias = Path(directory) / 'alias'
            alias.symlink_to(directory, target_is_directory=True)
            with patch.dict(os.environ, {'CHESS_PREP_JOB_CACHE': str(alias)}):
                with self.assertRaisesRegex(RuntimeError, 'symlink'):
                    jobs.storage_dir()
            with patch.dict(os.environ, {'CHESS_PREP_JOB_CACHE': 'relative'}):
                with self.assertRaisesRegex(RuntimeError, 'absolute'):
                    jobs.storage_dir()
            with patch.object(jobs.os, 'getuid', return_value=os.getuid() + 1):
                with self.assertRaisesRegex(RuntimeError, 'owned'):
                    jobs.storage_dir()

    def test_memory_backed_checkouts_and_caches_fail_before_job_launch(self):
        with patch.object(jobs.subprocess, 'check_output') as output:
            for kind in ('tmpfs', 'ramfs'):
                output.return_value = kind + '\n'
                with self.assertRaisesRegex(RuntimeError, 'move the checkout/cache to disk'):
                    jobs.require_disk_storage(Path('/example'))
            output.return_value = 'ext2/ext3\n'
            jobs.require_disk_storage(Path('/example'))
        with patch.object(jobs, 'require_disk_storage', side_effect=RuntimeError('RAM-backed')), \
                patch.object(jobs, 'setup') as setup:
            with self.assertRaisesRegex(RuntimeError, 'RAM-backed'):
                jobs.run(argparse.Namespace())
            setup.assert_not_called()

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
                patch.object(jobs, 'storage_dir', return_value=Path(directory)), \
                patch.object(jobs, 'require_disk_storage'), \
                patch.object(jobs, 'setup'), patch.object(jobs, 'xvfb_binary'), \
                patch.object(jobs.subprocess, 'run'), patch.object(jobs.subprocess, 'Popen') as spawn:
            spawn.return_value.poll.return_value = 0
            spawn.return_value.returncode = 0
            for headless in (False, True):
                self.assertEqual(jobs.run(argparse.Namespace(
                    headless=headless, offline=False, wait_seconds=10, command=['true'])), 0)
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
        with tempfile.TemporaryDirectory() as directory, patch.object(jobs, 'storage_dir', return_value=Path(directory)):
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
