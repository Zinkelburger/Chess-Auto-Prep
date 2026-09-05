#!/usr/bin/env python3
"""Bounded local jobs: run [--headless] -- COMMAND; status; setup.

Two machine-wide slots, one writer per checkout, and systemd-enforced limits.
Admission locks live inside the service. A dead supervisor cannot leave a job
running outside its reservation, and a failed user manager never runs uncapped.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
STATE = Path(f'/tmp/chess-prep-jobs-{os.getuid()}')
LEGACY_LOCK = Path('/tmp/chess-auto-prep-flutter.lock')
SLICE = 'chessprep.slice'
SLICE_CONFIG = '''[Unit]
Description=Chess Auto Prep agent workloads
[Slice]
CPUQuota=400%
CPUWeight=30
IOWeight=30
MemoryHigh=14G
MemoryMax=16G
MemorySwapMax=0
'''


def checkout_key(path: Path) -> str:
    return hashlib.sha256(str(path.resolve()).encode()).hexdigest()[:16]


def driver_dir(path: Path) -> Path:
    return STATE / 'drivers' / checkout_key(path)


def process_token(pid: int) -> str:
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
        return '' if fields[0] == 'Z' else fields[19]
    except (OSError, IndexError):
        return ''


def current_cgroup() -> str:
    return Path('/proc/self/cgroup').read_text().strip().split('0::', 1)[1]


def populated(group: str) -> bool:
    try:
        return 'populated 1' in (Path('/sys/fs/cgroup') / group.lstrip('/') / 'cgroup.events').read_text()
    except OSError:
        return False


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


class Lease:
    """flock plus the previous service's lifetime, including leaked children."""
    def __init__(self, path: Path, metadata: dict | None = None, shared=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path, self.metadata, self.shared = path, metadata, shared
        self.fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        self.held = False

    def try_acquire(self) -> bool:
        try:
            fcntl.flock(self.fd, (fcntl.LOCK_SH if self.shared else fcntl.LOCK_EX) | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        if self.metadata is not None:
            previous = read_json(self.path.with_suffix('.json'))
            group = previous.get('cgroup', '')
            if group and group != self.metadata.get('cgroup') and populated(group):
                fcntl.flock(self.fd, fcntl.LOCK_UN)
                return False
            self.path.with_suffix('.json').write_text(json.dumps(self.metadata))
        self.held = True
        return True

    def close(self):
        os.close(self.fd)


def setup() -> None:
    if not shutil.which('systemd-run') or not Path(f'/run/user/{os.getuid()}/bus').exists():
        raise RuntimeError('A working systemd user manager is required; no uncapped fallback. Use remote CI on other hosts.')
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (STATE / 'setup.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        user_units = Path.home() / '.config/systemd/user'
        config = user_units / SLICE
        limits = user_units / (SLICE + '.d') / '90-agent-resources.conf'
        changed = False
        for path, contents in [(config, '[Unit]\nDescription=Chess Auto Prep agent workloads\n'),
                               (limits, SLICE_CONFIG)]:
            if not path.exists() or path.read_text() != contents:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
                changed = True
        if changed:
            subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True, timeout=15)
        active = subprocess.check_output(['systemctl', '--user', 'show', SLICE,
                    '-p', 'ActiveState', '--value'], text=True, timeout=10).strip()
        if active != 'active':
            subprocess.run(['systemctl', '--user', 'start', SLICE], check=True, timeout=15)
        # Distribution/user-wide slice drop-ins can override a unit's main
        # file. Verify effective settings, including parent memory ceilings.
        result = subprocess.check_output(['systemctl', '--user', 'show', SLICE,
                    '-p', 'MemoryMax', '-p', 'EffectiveMemoryMax',
                    '-p', 'CPUQuotaPerSecUSec'], text=True, timeout=10)
        values = dict(line.split('=', 1) for line in result.splitlines() if '=' in line)
        if values.get('MemoryMax') != str(16 * 1024**3) or values.get('CPUQuotaPerSecUSec') != '4s':
            raise RuntimeError('An existing systemd override conflicts with the agent resource budget: ' + result.strip())
        if int(values.get('EffectiveMemoryMax', 0)) < 16 * 1024**3:
            raise RuntimeError('A parent cgroup gives agent jobs less than the configured 16 GiB budget')


def profile_env(checkout: Path) -> dict[str, str]:
    env = dict(os.environ)
    profile = driver_dir(checkout) / 'profile'
    for suffix in ['config', 'data', 'cache', 'state', 'Documents', 'Downloads', 'runtime']:
        (profile / suffix).mkdir(parents=True, exist_ok=True, mode=0o700)
    for var, suffix in [('XDG_CONFIG_HOME', 'config'), ('XDG_DATA_HOME', 'data'),
                        ('XDG_CACHE_HOME', 'cache'), ('XDG_STATE_HOME', 'state')]:
        env[var] = str(profile / suffix)
    # path_provider and GLib both read this file. HOME stays untouched.
    (profile / 'config/user-dirs.dirs').write_text(
        f'XDG_DOCUMENTS_DIR="{profile / "Documents"}"\n'
        f'XDG_DOWNLOAD_DIR="{profile / "Downloads"}"\n')
    env['CHESS_AUTO_PREP_NEW_INSTANCE'] = '1'
    env['OMP_NUM_THREADS'] = '1'
    env['OPENBLAS_NUM_THREADS'] = '1'
    env['CMAKE_BUILD_PARALLEL_LEVEL'] = '2'
    return env


def xvfb_binary() -> str:
    found = shutil.which('Xvfb')
    local = Path.home() / '.local/share/chess-prep/xvfb/usr/bin/Xvfb'
    if found:
        return found
    if local.is_file():
        return str(local)
    raise RuntimeError('Xvfb is missing. Run scripts/setup_agent_display.sh; headless jobs never open the real display as a fallback.')


@contextlib.contextmanager
def display(env: dict, headless: bool):
    if not headless:
        yield env
        return
    binary = xvfb_binary()
    read_fd, write_fd = os.pipe()
    child_env = dict(env)
    local_lib = str(Path(binary).parent.parent / 'lib64')
    child_env['LD_LIBRARY_PATH'] = local_lib + ':' + env.get('LD_LIBRARY_PATH', '')
    proc = subprocess.Popen([binary, '-displayfd', str(write_fd), '-screen', '0',
                             '1280x720x24', '-nolisten', 'tcp', '-noreset'],
                            pass_fds=(write_fd,), env=child_env,
                            stdout=subprocess.DEVNULL, stderr=sys.stderr)
    os.close(write_fd)
    try:
        if not select.select([read_fd], [], [], 10)[0]:
            raise RuntimeError('Xvfb did not start within 10 seconds')
        number = os.read(read_fd, 64).decode().strip()
        if not number.isdecimal() or proc.poll() is not None:
            raise RuntimeError('Xvfb failed to allocate a private display')
        isolated = dict(env, DISPLAY=f':{number}', GDK_BACKEND='x11', LIBGL_ALWAYS_SOFTWARE='1')
        isolated.pop('WAYLAND_DISPLAY', None)
        # A private session bus prevents GTK/file-open handoffs to the user's app.
        yield isolated
    finally:
        os.close(read_fd)
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait()


def run_child(command: list[str], env: dict, owner: int, token: str) -> int:
    proc = subprocess.Popen(command, env=env, start_new_session=True)
    try:
        while proc.poll() is None:
            if process_token(owner) != token:
                raise RuntimeError('Launching agent exited; cancelling its job')
            time.sleep(0.2)
        return proc.returncode
    finally:
        # Include background children in the group; systemd also kills any
        # child that escaped it via setsid when this worker exits.
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL); proc.wait()


def worker(args) -> int:
    group = current_cgroup()
    if '/chess-prep-job-' not in group or not group.endswith('.service'):
        raise RuntimeError('Internal worker must run inside its bounded systemd service')
    if args.ready:
        Path(args.ready).touch()
    metadata = {'pid': os.getpid(), 'cgroup': group, 'checkout': str(Path.cwd()),
                'command': args.command[:3], 'started': time.time()}
    deadline = time.monotonic() + args.wait_seconds
    def wait_for(leases):
        announced = False
        while True:
            if process_token(args.owner) != args.token:
                raise RuntimeError('Launching agent exited while queued')
            for lease in leases:
                if lease.try_acquire():
                    return lease
            if not announced:
                print('agent-job: queued for ' + leases[0].path.name, file=sys.stderr, flush=True)
                announced = True
            if time.monotonic() >= deadline:
                raise RuntimeError('Queue timeout; use scripts/ci.sh status and do other work before retrying')
            time.sleep(0.2)
    with contextlib.ExitStack() as stack:
        # Old checkouts still take an exclusive legacy lock. New checkouts
        # share it, so old jobs and the two-slot setup never overlap.
        legacy = Lease(LEGACY_LOCK, shared=True); stack.callback(legacy.close)
        wait_for([legacy])
        checkout = Lease(STATE / ('checkout-' + checkout_key(Path.cwd()) + '.lock'), metadata)
        stack.callback(checkout.close); wait_for([checkout])
        slots = [Lease(STATE / f'slot-{i}.lock', metadata) for i in range(2)]
        for slot in slots:
            stack.callback(slot.close)
        active = wait_for(slots)
        print(f'agent-job: {active.path.stem}, 2 CPUs, 8 GiB maximum', file=sys.stderr, flush=True)
        env = profile_env(Path.cwd())
        with display(env, args.headless) as child_env:
            command = args.command
            if args.headless:
                if not shutil.which('dbus-run-session'):
                    raise RuntimeError('dbus-run-session is required for an isolated desktop test')
                command = ['dbus-run-session', '--', *command]
            return run_child(command, child_env, args.owner, args.token)


def run(args) -> int:
    setup()
    if args.headless:
        xvfb_binary()  # Fail before queuing, never fall back to a visible app.
    unit = f'chess-prep-job-{os.getpid()}-{uuid.uuid4().hex[:8]}'
    ready = STATE / (unit + '.ready')
    command = ['systemd-run', '--user', '--quiet', '--wait', '--pipe', '--collect',
               '--service-type=exec', '--expand-environment=no', '--unit', unit,
               '--slice', SLICE, '--working-directory', str(Path.cwd()),
               '-p', 'CPUQuota=200%', '-p', 'MemoryHigh=6G', '-p', 'MemoryMax=8G',
               '-p', 'MemorySwapMax=0', '-p', 'KillMode=control-group',
               '-p', 'TimeoutStopSec=5s', '-p', 'OOMPolicy=stop', '-p', 'OOMScoreAdjust=800']
    for name in os.environ:
        if name not in {'INVOCATION_ID', 'JOURNAL_STREAM', 'NOTIFY_SOCKET'}:
            command.append('--setenv=' + name)
    command += ['--', sys.executable, str(Path(__file__).resolve()), '_worker',
                '--owner', str(os.getpid()), '--token', process_token(os.getpid()),
                '--wait-seconds', str(args.wait_seconds), '--ready', str(ready)]
    if args.headless:
        command.append('--headless')
    command += ['--', *args.command]
    parent = os.getppid()
    parent_token = process_token(parent)
    proc = subprocess.Popen(command)
    startup_deadline = time.monotonic() + 30
    try:
        while proc.poll() is None:
            if not ready.exists() and time.monotonic() > startup_deadline:
                raise RuntimeError('User manager did not start the bounded service within 30 seconds')
            if process_token(parent) != parent_token:
                raise RuntimeError('Launching process exited; stopping its service')
            time.sleep(0.2)
        return proc.returncode
    finally:
        # Bound the call even when the user manager is unhealthy. The worker
        # independently notices its owner disappearing and stops its child.
        try:
            subprocess.run(['systemctl', '--user', 'stop', unit + '.service'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        except subprocess.TimeoutExpired:
            pass
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait()
        ready.unlink(missing_ok=True)


def status() -> None:
    for i in range(2):
        metadata = read_json(STATE / f'slot-{i}.json')
        busy = populated(metadata.get('cgroup', '')) if metadata.get('cgroup') else False
        print(f'slot {i}: ' + (f"busy · {metadata.get('checkout')} · {metadata.get('command')}" if busy else 'free'))
    lease = Lease(LEGACY_LOCK, shared=True)
    try:
        if not lease.try_acquire():
            print('legacy exclusive job active; new jobs will wait for it')
    finally:
        lease.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['run', '_worker', 'status', 'setup'])
    parser.add_argument('--headless', action='store_true')
    parser.add_argument('--wait-seconds', type=float, default=120)
    parser.add_argument('--owner', type=int, default=0)
    parser.add_argument('--token', default='')
    parser.add_argument('--ready', default='')
    argv = sys.argv[1:]
    split = argv.index('--') if '--' in argv else len(argv)
    args = parser.parse_args(argv[:split]); args.command = argv[split + 1:]
    if args.action in {'run', '_worker'} and not args.command:
        parser.error('provide a command after --')
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        if args.action == 'run':
            return run(args)
        if args.action == '_worker':
            return worker(args)
        if args.action == 'setup':
            setup(); print('Agent job limits installed')
        else:
            status()
        return 0
    except KeyboardInterrupt:
        return 130
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f'agent-job: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
