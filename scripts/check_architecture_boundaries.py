#!/usr/bin/env python3
"""Enforce renewal boundaries as slices migrate; legacy paths are not certified."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DIRECTIVE = re.compile(r"^\s*(?:import|export)\s+['\"]([^'\"]+)['\"]", re.M)


def violations(relative: str, source: str) -> list[str]:
    path = Path(relative)
    feature = relative.startswith(('lib/features/repertoires/', 'lib/features/documents/', 'lib/features/settings/'))
    infrastructure = relative.startswith('lib/infrastructure/')
    if not (feature or infrastructure):
        return []
    pure = feature and any(part in ('models', 'repositories') for part in path.parts[3:-1])
    controller = feature and 'controllers' in path.parts[3:-1]
    errors = []
    for uri in DIRECTIVE.findall(source):
        if uri.startswith('package:chess_auto_prep/'):
            target = ROOT / 'lib' / uri.split('/', 1)[1]
        elif ':' not in uri:
            target = (ROOT / path.parent / uri).resolve()
        else:
            target = None
        local = target.relative_to(ROOT).as_posix() if target and target.is_relative_to(ROOT) else ''
        forbidden = (
            pure and (uri.startswith(('dart:io', 'dart:isolate', 'dart:ffi', 'package:flutter', 'package:riverpod')) or local.startswith(('lib/services/', 'lib/infrastructure/', 'lib/app/')))
            or feature and (uri.startswith(('dart:io', 'dart:ffi', 'package:document_file_io/', 'package:shared_preferences/')) or local.startswith(('lib/infrastructure/', 'lib/app/', 'lib/services/storage/')))
            or controller and ('/widgets/' in local or '/screens/' in local or local.startswith('lib/services/'))
            or (pure or controller or infrastructure) and local.startswith('lib/l10n/')
            or infrastructure and ('/widgets/' in local or '/screens/' in local or '/controllers/' in local or local.startswith('lib/app/'))
        )
        if forbidden:
            errors.append(f'{relative}: forbidden dependency {uri}')
    if feature and re.search(r'\b\w+\.instance\b', source):
        errors.append(f'{relative}: global singleton access bypasses injection')
    return errors


def main() -> int:
    errors = []
    for folder in ('lib/features/repertoires', 'lib/features/documents', 'lib/features/settings', 'lib/infrastructure'):
        for path in (ROOT / folder).rglob('*.dart'):
            errors.extend(violations(path.relative_to(ROOT).as_posix(), path.read_text()))
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print('Renewal architecture boundaries: OK (catalog, documents, settings and infrastructure)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
