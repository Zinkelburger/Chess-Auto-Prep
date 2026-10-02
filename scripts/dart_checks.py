#!/usr/bin/env python3
"""Shared local/CI Dart gates; invoke locally through scripts/ci.sh."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def clean_head():
    status = subprocess.check_output(
        ['git', 'status', '--porcelain', '--untracked-files=all'], text=True,
    )
    if status:
        raise RuntimeError(f'Release preflight requires a clean checkout:\n{status}')
    return subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()


def run(gate, flutter, extra=()):
    os.chdir(ROOT)
    logs = ROOT / 'build/quality-gates'
    logs.mkdir(parents=True, exist_ok=True)
    # Avoid presenting logs from an earlier run as results of this preflight.
    if gate == 'preflight':
        for old in logs.glob('*.log'):
            old.unlink()
    summary = []
    current = 'checkout' if gate == 'preflight' else 'sdk'

    def command(name, args):
        nonlocal current
        current = name
        print(f'── {name}', flush=True)
        with (logs / f'{name}.log').open('w') as log:
            with subprocess.Popen(args, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True) as child:
                for line in child.stdout:
                    print(line, end='', flush=True)
                    log.write(line)
                code = child.wait()
        if code:
            raise RuntimeError(f'{name} exited with status {code}')
        summary.append(f'- {name}: passed')

    try:
        head = clean_head() if gate == 'preflight' else None
        if head:
            summary.append(f'Commit: `{head}`\n')
        current = 'sdk'
        expected = json.loads((ROOT / '.fvmrc').read_text())['flutter']
        executable = shutil.which(flutter)
        if not executable:
            raise RuntimeError(f'Flutter executable not found: {flutter}')
        command('sdk', [executable, '--version', '--machine'])
        # Flutter may print a line before the JSON, such as "Waiting for
        # another flutter command to release the startup lock...".
        text = (logs / 'sdk.log').read_text()
        actual = json.JSONDecoder().raw_decode(text, text.index('{'))[0]['frameworkVersion']
        if actual != expected:
            raise RuntimeError(
                f'Flutter {expected} required by .fvmrc; found {actual}. '
                'Set FLUTTER to the pinned SDK executable.'
            )
        dart = str(Path(executable).resolve().with_name('dart'))
        if gate == 'preflight':
            command('dependencies', [executable, 'pub', 'get'])
        if gate in ('preflight', 'format-check'):
            command('format', [dart, 'format', '--output=none',
                               '--set-exit-if-changed', 'lib', 'test', 'integration_test'])
        if gate in ('preflight', 'analyze'):
            targets = ['lib', 'test', 'integration_test']
            targets.extend(p for p in ('test_driver',) if Path(p).is_dir())
            command('analyze', [executable, 'analyze', *targets, '--no-fatal-infos'])
        if gate in ('preflight', 'test'):
            command('test', [executable, 'test', '--concurrency=2',
                             '--reporter', 'expanded', *extra])
        if head:
            current = 'checkout'
            if clean_head() != head:
                raise RuntimeError('HEAD changed during preflight; validate the final commit again')
            summary.append('- checkout: clean; HEAD unchanged')
        return 0
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        summary = [line for line in summary if line != f'- {current}: passed']
        message = f'First failed gate: {current}: {error}'
        print(message, file=sys.stderr)
        summary.append(message)
        (logs / 'failure.log').write_text(message + '\n')
        return 1
    finally:
        report = '## Dart quality gates\n\n' + '\n'.join(summary) + '\n'
        (logs / 'summary.md').write_text(report)
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
                output.write(report)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('gate', choices=['format-check', 'analyze', 'test', 'preflight'])
    parser.add_argument('--flutter', default=os.environ.get('FLUTTER', 'flutter'))
    args_in = sys.argv[1:]
    split = args_in.index('--') if '--' in args_in else len(args_in)
    args = parser.parse_args(args_in[:split])
    extra = args_in[split + 1:]
    if extra and args.gate != 'test':
        parser.error('extra arguments are only accepted for test')
    sys.exit(run(args.gate, args.flutter, extra))
