#!/usr/bin/env python3
"""Enforce renewal boundaries as slices migrate; legacy paths are not certified."""
from pathlib import Path
import re
import json
import posixpath
import sys

ROOT = Path(__file__).resolve().parents[1]
DIRECTIVE = re.compile(r"^\s*(?:import|export)\s+['\"]([^'\"]+)['\"]", re.M)
DEPENDENCIES = re.compile(r"^\s*(?:import|export|part)\s+([^;]+);", re.M)
RETIRED_BUILDER_LIBRARIES = {
    'lib/core/repertoire_controller.dart',
    'lib/core/repertoire_writer.dart',
    'lib/core/repertoire_authoring.dart',
    'lib/core/move_navigation.dart',
    'lib/services/repertoire_line_expansion.dart',
    'lib/services/course_chapter_headers.dart',
}


def pure_dependency_violations(sources: dict[str, str], roots: list[str]) -> list[str]:
    """Follow project imports/exports/parts, including conditional alternatives.

    Converted chess code and the Viewer game owner must run without Flutter or
    native I/O even when a dependency still has a legacy utility path.
    """
    errors = []
    for root in roots:
        pending = [(root, [root])]
        seen = set()
        while pending:
            path, chain = pending.pop()
            if path in seen or path not in sources:
                continue
            seen.add(path)
            for directive in DEPENDENCIES.findall(sources[path]):
                for uri in re.findall(r"['\"]([^'\"]+)['\"]", directive):
                    if uri in ('dart:ui', 'dart:io', 'dart:ffi', 'dart:isolate') or uri.startswith(('package:flutter', 'package:riverpod')):
                        errors.append(f"{root}: impure dependency chain {' -> '.join([*chain, uri])}")
                        continue
                    if uri.startswith('package:chess_auto_prep/'):
                        target = 'lib/' + uri.split('/', 1)[1]
                    elif ':' not in uri:
                        target = posixpath.normpath(posixpath.join(posixpath.dirname(path), uri))
                    else:
                        continue
                    pending.append((target, [*chain, target]))
    return errors


def violations(relative: str, source: str) -> list[str]:
    path = Path(relative)
    errors = []
    executable = re.sub(r'(?m)^\s*//.*$', '', source)
    if relative in RETIRED_BUILDER_LIBRARIES:
        errors.append(f'{relative}: retired Builder library; use the canonical feature/chess-core owner')
    if relative.startswith('lib/') and relative != 'lib/chess_core/pgn/pgn_parser.dart' and re.search(r'\bPgnGame\.parsePgn\s*\(', executable):
        errors.append(f'{relative}: single-game parsing must use chess_core/pgn/pgn_parser.dart')
    if relative in ('lib/features/repertoires/controllers/repertoire_controller.dart', 'lib/features/repertoires/controllers/repertoire_writer.dart'):
        for uri in DIRECTIVE.findall(source):
            if uri.startswith(('dart:io', 'dart:isolate')) or any(part in uri for part in ('infrastructure/', 'services/storage/', 'repertoire_file_editor.dart')):
                errors.append(f'{relative}: Builder document access must use injected contracts: {uri}')
        if re.search(r'\b\w+\.instance\b', executable):
            errors.append(f'{relative}: Builder bypasses injected document dependencies')
    feature = relative.startswith(('lib/features/repertoires/', 'lib/features/documents/', 'lib/features/settings/', 'lib/features/studies/'))
    chess = relative.startswith('lib/chess_core/')
    infrastructure = relative.startswith('lib/infrastructure/')
    design = relative.startswith('lib/design_system/')
    catalog = relative.startswith('widgetbook/')
    if not (feature or infrastructure or design or catalog or chess):
        return errors
    pure = chess or feature and any(part in ('models', 'repositories') for part in path.parts[3:-1])
    controller = feature and 'controllers' in path.parts[3:-1]
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
            or relative.startswith(('lib/features/repertoires/widgets/', 'lib/features/documents/widgets/', 'lib/features/settings/widgets/', 'lib/features/studies/widgets/')) and local.startswith('lib/theme/')
            or pure and (uri.startswith(('dart:io', 'dart:isolate', 'dart:ffi', 'package:flutter', 'package:riverpod')) or local.startswith(('lib/services/', 'lib/infrastructure/', 'lib/app/')))
            or feature and (uri.startswith(('dart:io', 'dart:ffi', 'package:document_file_io/', 'package:shared_preferences/')) or local.startswith(('lib/infrastructure/', 'lib/app/', 'lib/services/storage/')))
            or controller and ('/widgets/' in local or '/screens/' in local or local.startswith('lib/services/'))
            or (pure or controller or infrastructure) and local.startswith(('lib/l10n/', 'lib/design_system/'))
            or infrastructure and ('/widgets/' in local or '/screens/' in local or '/controllers/' in local or local.startswith('lib/app/'))
        )
        if forbidden:
            errors.append(f'{relative}: forbidden dependency {uri}')
    if (design and not relative.startswith('lib/design_system/theme/') or relative.startswith(('lib/features/repertoires/widgets/', 'lib/features/documents/widgets/', 'lib/features/settings/widgets/', 'lib/features/studies/widgets/'))) and re.search(r'\b(?:AppColors|AppTextStyles|AppPalette)\b|\bColors\.|\bColor(?:\.fromARGB|\.fromRGBO)?\s*\(|\bfontSize\s*:', source):
        errors.append(f'{relative}: widget bypasses active theme/typography')
    # A widget's frame scheduling is framework lifecycle, not an application
    # service locator. Keep this exception narrow; domain owners still inject
    # their schedulers, and storage/engine singletons remain forbidden in UI.
    singleton_access = re.findall(r'\b(\w+)\.instance\b', source)
    if feature and 'widgets' in path.parts[3:-1]:
        singleton_access = [name for name in singleton_access if name != 'WidgetsBinding']
    if (feature or catalog) and singleton_access:
        errors.append(f'{relative}: global singleton access bypasses injection')
    return errors


def main() -> int:
    errors = []
    sources = {path.relative_to(ROOT).as_posix(): path.read_text() for path in (ROOT / 'lib').rglob('*.dart')}
    pure_roots = [path for path in sources if path.startswith('lib/chess_core/')]
    pure_roots.extend([
        'lib/features/documents/controllers/viewer_game_controller.dart',
        'lib/features/documents/controllers/viewer_game_load_controller.dart',
        'lib/features/documents/controllers/viewer_session_controller.dart',
        'lib/features/documents/controllers/viewer_collection_load_controller.dart',
        'lib/features/documents/controllers/viewer_filter_controller.dart',
        'lib/features/documents/controllers/viewer_presentation_controller.dart',
        'lib/features/documents/controllers/viewer_collection_controller.dart',
        'lib/features/repertoires/controllers/repertoire_board_controller.dart',
        'lib/features/repertoires/controllers/repertoire_line_edits.dart',
        'lib/features/repertoires/models/repertoire_authoring.dart',
        'lib/features/repertoires/models/loaded_repertoire.dart',
        'lib/features/repertoires/repositories/repertoire_decoder.dart',
        'lib/features/repertoires/repositories/repertoire_document_repository.dart',
    ])
    errors.extend(pure_dependency_violations(sources, pure_roots))
    for folder in ('lib/features/repertoires', 'lib/features/documents', 'lib/features/settings', 'lib/features/studies', 'lib/chess_core', 'lib/infrastructure', 'lib/design_system', 'widgetbook'):
        for path in (ROOT / folder).rglob('*.dart'):
            errors.extend(violations(path.relative_to(ROOT).as_posix(), path.read_text()))
    checked_roots = ('lib/features/repertoires/', 'lib/features/documents/', 'lib/features/settings/', 'lib/features/studies/', 'lib/chess_core/', 'lib/infrastructure/', 'lib/design_system/')
    for path in (ROOT / 'lib').rglob('*.dart'):
        relative = path.relative_to(ROOT).as_posix()
        if not relative.startswith(checked_roots):
            errors.extend(violations(relative, path.read_text()))
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
    print('Renewal architecture boundaries: OK (catalog, documents, studies, settings, chess core, infrastructure and design system)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
