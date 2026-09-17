#!/usr/bin/env python3
"""Enforce renewal boundaries as slices migrate; legacy paths are not certified."""
from pathlib import Path
import re
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
DIRECTIVE = re.compile(r"^\s*(?:import|export)\s+['\"]([^'\"]+)['\"]", re.M)


def violations(relative: str, source: str) -> list[str]:
    path = Path(relative)
    feature = relative.startswith(('lib/features/repertoires/', 'lib/features/documents/', 'lib/features/settings/'))
    infrastructure = relative.startswith('lib/infrastructure/')
    design = relative.startswith('lib/design_system/')
    catalog = relative.startswith('widgetbook/')
    if not (feature or infrastructure or design or catalog):
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
            design and (uri.startswith(('dart:io', 'dart:ffi', 'package:provider/', 'package:flutter_riverpod/', 'package:widgetbook/')) or (local and not local.startswith('lib/design_system/')))
            or catalog and (uri.startswith(('dart:io', 'dart:ffi')) or local.startswith(('lib/infrastructure/', 'lib/app/', 'lib/services/storage/')))
            or relative.startswith('lib/features/repertoires/widgets/') and local.startswith('lib/theme/')
            or pure and (uri.startswith(('dart:io', 'dart:isolate', 'dart:ffi', 'package:flutter', 'package:riverpod')) or local.startswith(('lib/services/', 'lib/infrastructure/', 'lib/app/')))
            or feature and (uri.startswith(('dart:io', 'dart:ffi', 'package:document_file_io/', 'package:shared_preferences/')) or local.startswith(('lib/infrastructure/', 'lib/app/', 'lib/services/storage/')))
            or controller and ('/widgets/' in local or '/screens/' in local or local.startswith('lib/services/'))
            or (pure or controller or infrastructure) and local.startswith(('lib/l10n/', 'lib/design_system/'))
            or infrastructure and ('/widgets/' in local or '/screens/' in local or '/controllers/' in local or local.startswith('lib/app/'))
        )
        if forbidden:
            errors.append(f'{relative}: forbidden dependency {uri}')
    if (design and not relative.startswith('lib/design_system/theme/') or relative.startswith('lib/features/repertoires/widgets/')) and re.search(r'\b(?:AppColors|AppTextStyles|AppPalette)\b|\bColors\.|\bColor(?:\.fromARGB|\.fromRGBO)?\s*\(|\bfontSize\s*:', source):
        errors.append(f'{relative}: widget bypasses active theme/typography')
    if (feature or catalog) and re.search(r'\b\w+\.instance\b', source):
        errors.append(f'{relative}: global singleton access bypasses injection')
    return errors


def main() -> int:
    errors = []
    for folder in ('lib/features/repertoires', 'lib/features/documents', 'lib/features/settings', 'lib/infrastructure', 'lib/design_system', 'widgetbook'):
        for path in (ROOT / folder).rglob('*.dart'):
            errors.extend(violations(path.relative_to(ROOT).as_posix(), path.read_text()))
    legacy = json.loads((ROOT / 'scripts/legacy_theme_consumers.json').read_text())
    observed = set()
    for path in (ROOT / 'lib').rglob('*.dart'):
        relative = path.relative_to(ROOT).as_posix()
        if relative.startswith('lib/theme/'):
            continue
        if any(uri.endswith(('/theme/app_colors.dart', '/theme/app_text_styles.dart', '/theme/pgn_text_styles.dart')) for uri in DIRECTIVE.findall(path.read_text())):
            observed.add(relative)
    for relative in sorted(observed - legacy.keys()):
        errors.append(f'{relative}: new legacy theme consumer; migrate to design_system')
    for relative in sorted(legacy.keys() - observed):
        errors.append(f'{relative}: remove retired consumer from legacy_theme_consumers.json')
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print('Renewal architecture boundaries: OK (catalog, documents, settings, infrastructure and design system)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
