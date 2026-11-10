#!/usr/bin/env python3
"""List out-of-date dependencies across the repository. Changes nothing.

Run it now and then instead of letting a bot open pull requests:

    python3 scripts/outdated_deps.py            # everything
    python3 scripts/outdated_deps.py dart npm   # only some ecosystems

Ecosystems: dart (every pubspec.yaml, through `flutter pub outdated`),
npm (every package.json with installed node_modules), python (every
requirements*.txt `==`/`~=` pin against PyPI;
`>=` floors already install the latest) and actions (commit-pinned GitHub
Actions against each action's latest release). Exit status is 0 whether or
not anything is outdated; a source that cannot be checked is reported and
skipped.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
USER_AGENT = 'outdated-deps-scanner'
SKIP_DIRS = {'build', 'node_modules', '.dart_tool', '.git', 'ephemeral'}


def tracked(name_pattern):
    """Tracked files whose basename matches `name_pattern`."""
    out = subprocess.run(['git', 'ls-files'], cwd=ROOT, capture_output=True,
                         text=True, check=True).stdout.splitlines()
    return [ROOT / f for f in out
            if re.fullmatch(name_pattern, Path(f).name)
            and not SKIP_DIRS.intersection(Path(f).parts)]


def fetch_json(url, headers=None):
    request = urllib.request.Request(url, headers={'User-Agent': USER_AGENT,
                                                   **(headers or {})})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


# ── Dart ────────────────────────────────────────────────────────────────

def parse_pub_outdated(report):
    """Rows (package, kind, current, resolvable, latest) for outdated packages."""
    rows = []
    for package in report.get('packages', []):
        current = (package.get('current') or {}).get('version')
        latest = (package.get('latest') or {}).get('version')
        if not current or not latest or current == latest:
            continue
        rows.append((package['package'], package.get('kind', ''), current,
                     (package.get('resolvable') or {}).get('version', ''), latest))
    return rows


def flutter_binary():
    sdk = Path.home() / 'sdk/flutter/bin/flutter'
    return str(sdk) if sdk.exists() else shutil.which('flutter')


def check_dart():
    flutter = flutter_binary()
    if not flutter:
        return ['  skipped: flutter not found']
    lines = []
    for pubspec in tracked(r'pubspec\.yaml'):
        where = pubspec.parent.relative_to(ROOT)
        result = subprocess.run([flutter, 'pub', 'outdated', '--json'],
                                cwd=pubspec.parent, capture_output=True, text=True)
        try:
            rows = parse_pub_outdated(json.loads(result.stdout))
        except json.JSONDecodeError:
            lines.append(f'  {where}: could not check ({result.stderr.strip()[:200]})')
            continue
        direct = [r for r in rows if r[1] in ('direct', 'dev')]
        lines.append(f'  {where}: {len(direct)} direct, {len(rows) - len(direct)} transitive outdated')
        for name, kind, current, resolvable, latest in direct:
            note = '' if resolvable == latest else f' (constraints allow {resolvable})'
            lines.append(f'    {name} {current} -> {latest}{note}  [{kind}]')
    return lines


# ── npm ─────────────────────────────────────────────────────────────────

def check_npm():
    npm = shutil.which('npm')
    if not npm:
        return ['  skipped: npm not found']
    lines = []
    for manifest in tracked(r'package\.json'):
        where = manifest.parent.relative_to(ROOT)
        if not (manifest.parent / 'node_modules').is_dir():
            lines.append(f'  {where}: skipped, run `npm ci` there first')
            continue
        # `npm outdated` exits 1 when something is outdated.
        result = subprocess.run([npm, 'outdated', '--json'], cwd=manifest.parent,
                                capture_output=True, text=True)
        try:
            report = json.loads(result.stdout or '{}')
        except json.JSONDecodeError:
            lines.append(f'  {where}: could not check ({result.stderr.strip()[:200]})')
            continue
        lines.append(f'  {where}: {len(report)} outdated')
        for name, info in sorted(report.items()):
            if isinstance(info, list):  # workspaces report one entry per location
                info = info[0]
            wanted = info.get('wanted')
            note = '' if wanted == info.get('latest') else f' (range allows {wanted})'
            lines.append(f"    {name} {info.get('current')} -> {info.get('latest')}{note}")
    return lines


# ── Python ──────────────────────────────────────────────────────────────

REQUIREMENT = re.compile(r'^([A-Za-z0-9][A-Za-z0-9._-]*)(?:\[[^\]]*\])?\s*(==|>=|~=)\s*([^\s;,#]+)')


def parse_requirements(text):
    """(name, operator, version) for each pinned or floored requirement."""
    return [m.groups() for m in map(REQUIREMENT.match, text.splitlines()) if m]


def version_key(version):
    return tuple(int(part) for part in re.findall(r'\d+', version)[:4])


def check_python():
    lines = []
    for requirements in tracked(r'requirements[^/]*\.txt'):
        where = requirements.relative_to(ROOT)
        behind = []
        # A `>=` floor already installs the latest release; only pins can lag.
        for name, op, version in parse_requirements(requirements.read_text()):
            if op == '>=':
                continue
            try:
                latest = fetch_json(f'https://pypi.org/pypi/{name}/json')['info']['version']
            except Exception as error:  # noqa: BLE001 - report and continue
                behind.append(f'    {name}: could not check ({error})')
                continue
            if version_key(latest) > version_key(version):
                behind.append(f'    {name} {op}{version} -> {latest}')
        lines.append(f'  {where}: {len(behind)} behind')
        lines.extend(behind)
    return lines


# ── GitHub Actions ──────────────────────────────────────────────────────

USES = re.compile(r'uses:\s*([\w.-]+/[\w.-]+)(?:/[^@\s]*)?@([0-9a-f]{40})(?:\s*#\s*(\S+))?')


def parse_action_pins(text):
    """{action: (sha, version comment)} for each commit-pinned action."""
    return {m.group(1): (m.group(2), m.group(3) or '') for m in USES.finditer(text)}


def github_api(path):
    """GET a GitHub API path, through `gh` when it is logged in."""
    if shutil.which('gh'):
        result = subprocess.run(['gh', 'api', path], capture_output=True, text=True)
        if result.returncode == 0:
            return json.loads(result.stdout)
    token = os.environ.get('GITHUB_TOKEN') or os.environ.get('GH_TOKEN')
    headers = {'Authorization': f'Bearer {token}'} if token else {}
    return fetch_json(f'https://api.github.com/{path}', headers)


def latest_release(action):
    """(tag, commit sha) of the action's latest release."""
    tag = github_api(f'repos/{action}/releases/latest')['tag_name']
    return tag, github_api(f'repos/{action}/commits/{tag}')['sha']


def check_actions():
    pins = {}
    for workflow in sorted((ROOT / '.github/workflows').glob('*.y*ml')):
        for action, pin in parse_action_pins(workflow.read_text()).items():
            pins.setdefault(action, set()).add(pin)
    lines = []
    for action, found in sorted(pins.items()):
        try:
            latest, latest_sha = latest_release(action)
        except Exception as error:  # noqa: BLE001 - report and continue
            lines.append(f'  {action}: could not check ({error})')
            continue
        for sha, comment in sorted(found):
            if sha != latest_sha:
                lines.append(f'  {action} {comment or sha[:12]} -> {latest} ({latest_sha})')
    if not lines:
        lines.append('  all pinned actions are on their latest release')
    return lines


CHECKS = {'dart': check_dart, 'npm': check_npm, 'python': check_python,
          'actions': check_actions}


def main(argv):
    wanted = argv or list(CHECKS)
    unknown = [name for name in wanted if name not in CHECKS]
    if unknown:
        sys.exit(f"Unknown ecosystem: {', '.join(unknown)}. Choose from {', '.join(CHECKS)}.")
    for name in wanted:
        print(f'── {name}')
        print('\n'.join(CHECKS[name]()), flush=True)


if __name__ == '__main__':
    main(sys.argv[1:])
