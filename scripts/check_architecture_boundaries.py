#!/usr/bin/env python3
"""Check every feature and ratchet exact, explicitly recorded architecture debt."""
from collections import Counter
from pathlib import Path
import re
import json
import posixpath
import sys

ROOT = Path(__file__).resolve().parents[1]
DIRECTIVE = re.compile(r"^\s*(?:import|export)\s+['\"]([^'\"]+)['\"]", re.M)
DEPENDENCIES = re.compile(r"^\s*(?:import|export|part)\s+([^;]+);", re.M)
FEATURE_STATES = {'unfinished', 'enforced', 'complete'}
THEME_USE = re.compile(r'\b(?:AppColors|AppTextStyles|AppPalette)\b|\bColors\.|\bColor(?:\.fromARGB|\.fromRGBO)?\s*\(|\bfontSize\s*:')
SINGLETON_USE = re.compile(r'\b(\w+)\.instance\b')
# Preserve source lines while ignoring comments. Retired names in interpolated
# strings can still be executable references, so literals are kept conservatively.
DART_TRIVIA = re.compile(r"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|//[^\n]*|/\*[\s\S]*?\*/")
RETIREMENTS = json.loads((ROOT / 'scripts/architecture_retirements.json').read_text())


def without_comments(source: str) -> str:
    return DART_TRIVIA.sub(
        lambda match: re.sub(r'[^\n]', ' ', match.group())
        if match.group().startswith(('//', '/*')) else match.group(), source)



def project_target(relative: str, uri: str) -> str:
    if uri.startswith('package:chess_auto_prep/'):
        return posixpath.normpath('lib/' + uri.split('/', 1)[1])
    if ':' not in uri:
        return posixpath.normpath(posixpath.join(posixpath.dirname(relative), uri))
    return ''


def dependency_uris(source: str):
    for directive in DEPENDENCIES.findall(source):
        yield from re.findall(r"['\"]([^'\"]+)['\"]", directive)


def retirement_violations(relative: str, source: str, retirements: dict) -> list[str]:
    if not relative.startswith('lib/'):
        return []
    errors = []
    executable = without_comments(source)
    dependencies = [(uri, project_target(relative, uri)) for uri in dependency_uris(executable)]
    for uri, _ in dependencies:
        if uri.startswith(('package:flutter_riverpod/', 'package:riverpod/')):
            errors.append(f'{relative}: retired Riverpod dependency {uri}; use constructor injection and Provider')
    for path in retirements['paths']:
        def retired(target):
            return target == path or path.endswith('/') and target.startswith(path)
        if retired(relative):
            errors.append(f'{relative}: retired library {path}; use its final owner')
        for uri, target in dependencies:
            if retired(target):
                errors.append(f'{relative}: dependency on retired library {uri}; use its final owner')
    for symbol in retirements['symbols']:
        if re.search(rf'\b{re.escape(symbol)}\b', executable):
            errors.append(f'{relative}: retired API {symbol}; use its final owner')
    return errors


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


def legacy_service_dependency_violations(sources: dict[str, str], roots: list[str]) -> list[str]:
    """Final artifact domain and enforced feature services cannot hide legacy
    service owners behind a model, export, conditional import, or part.

    Runtime scheduling remains allowed in application services; pure domain
    roots independently pass the stricter pure_dependency_violations check.
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
            for uri in dependency_uris(without_comments(sources[path])):
                target = project_target(path, uri)
                if target.startswith('lib/services/'):
                    errors.append(f"{root}: legacy service dependency chain {' -> '.join([*chain, target])}")
                elif target:
                    pending.append((target, [*chain, target]))
    return errors


def violations(relative: str, source: str, *, include_retirements: bool = True) -> list[str]:
    path = Path(relative)
    errors = retirement_violations(relative, source, RETIREMENTS) if include_retirements else []
    executable = without_comments(source)
    # lib/v2/ is the rewrite: it may not import the old app's chess_core, so it
    # reads PGN with its own reader and this consolidation rule does not apply.
    if relative.startswith('lib/') and not relative.startswith('lib/v2/') and relative != 'lib/chess_core/pgn/pgn_parser.dart' and re.search(r'\bPgnGame\.parsePgn\s*\(', executable):
        errors.append(f'{relative}: single-game parsing must use chess_core/pgn/pgn_parser.dart')
    if relative in ('lib/features/repertoires/controllers/builder_workspace_controller.dart', 'lib/features/repertoires/controllers/repertoire_writer.dart'):
        for uri in dependency_uris(without_comments(source)):
            if uri.startswith(('dart:io', 'dart:isolate')) or any(part in uri for part in ('infrastructure/', 'services/storage/', 'repertoire_file_editor.dart')):
                errors.append(f'{relative}: Builder document access must use injected contracts: {uri}')
        if re.search(r'\b\w+\.instance\b', executable):
            errors.append(f'{relative}: Builder bypasses injected document dependencies')
    feature = relative.startswith('lib/features/')
    widget = feature and 'widgets' in path.parts[3:-1]
    chess = relative.startswith('lib/chess_core/')
    infrastructure = relative.startswith('lib/infrastructure/')
    design = relative.startswith('lib/design_system/')
    catalog = relative.startswith('widgetbook/')
    if not (feature or infrastructure or design or catalog or chess):
        return errors
    pure = chess or feature and any(part in ('models', 'repositories') for part in path.parts[3:-1])
    controller = feature and 'controllers' in path.parts[3:-1]
    for uri in dependency_uris(without_comments(source)):
        local = project_target(relative, uri)
        forbidden = (
            design and (uri.startswith(('dart:io', 'dart:ffi', 'package:provider/', 'package:flutter_riverpod/', 'package:widgetbook/')) or (local and not local.startswith('lib/design_system/')))
            or catalog and (uri.startswith(('dart:io', 'dart:ffi')) or local.startswith(('lib/infrastructure/', 'lib/app/', 'lib/services/storage/')))
            or widget and local.startswith('lib/theme/')
            or pure and (uri.startswith(('dart:io', 'dart:isolate', 'dart:ffi', 'package:flutter', 'package:riverpod')) or local.startswith(('lib/services/', 'lib/infrastructure/', 'lib/app/')))
            or feature and (uri.startswith(('dart:io', 'dart:ffi', 'package:document_file_io/', 'package:shared_preferences/')) or local.startswith(('lib/infrastructure/', 'lib/app/', 'lib/services/storage/')))
            or controller and ('/widgets/' in local or '/screens/' in local or local.startswith('lib/services/'))
            or (pure or controller or infrastructure) and local.startswith(('lib/l10n/', 'lib/design_system/'))
            or infrastructure and ('/widgets/' in local or '/screens/' in local or '/controllers/' in local or local.startswith('lib/app/'))
        )
        if forbidden:
            errors.append(f'{relative}: forbidden dependency {uri}')
    if design and not relative.startswith('lib/design_system/theme/') or widget:
        for line, code in zip(source.splitlines(), executable.splitlines()):
            if THEME_USE.search(code):
                errors.append(f'{relative}: widget bypasses active theme/typography: {line.strip()}')
    # Keep every offending source line, including repeated lines. A file-level
    # exemption would silently allow new calls in already indebted files.
    if feature or catalog:
        for line, code in zip(source.splitlines(), executable.splitlines()):
            names = SINGLETON_USE.findall(code)
            if widget:
                names = [name for name in names if name != 'WidgetsBinding']
            if names:
                errors.append(f'{relative}: global singleton access bypasses injection: {line.strip()}')
    return errors


def feature_debt_violations(observed: set[str], findings: list[str], ledger: dict) -> list[str]:
    """An exact multiset ratchet: debt may disappear only with ledger removal."""
    errors = []
    features = ledger['features']
    baseline = ledger['baseline']
    for feature in sorted(observed - features.keys()):
        errors.append(f'lib/features/{feature}/: unclassified feature directory')
    for feature in sorted(features.keys() - observed):
        errors.append(f'lib/features/{feature}/: remove stale feature classification')
    for feature, state in features.items():
        if state not in FEATURE_STATES:
            errors.append(f'lib/features/{feature}/: invalid feature state {state!r}')
    for entry in baseline:
        path = entry.split(': ', 1)[0]
        parts = path.split('/')
        if len(parts) < 4 or parts[:2] != ['lib', 'features']:
            errors.append(f'{entry}: debt baseline may contain only feature findings')
        elif features.get(parts[2]) != 'unfinished':
            errors.append(f'{entry}: only unfinished features may retain baseline debt')
    current, recorded = Counter(findings), Counter(baseline)
    for entry, count in sorted((current - recorded).items()):
        errors.extend([f'{entry} [new violation; replace the dependency]'] * count)
    for entry, count in sorted((recorded - current).items()):
        errors.extend([f'{entry} [stale baseline; remove resolved debt]'] * count)
    return errors


def check(root: Path) -> tuple[list[str], int, int]:
    errors = []
    sources = {path.relative_to(root).as_posix(): path.read_text() for path in (root / 'lib').rglob('*.dart')}
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
        'lib/features/repertoires/controllers/repertoire_document_session.dart',
        'lib/features/generation/controllers/generation_publication_controller.dart',
        'lib/features/repertoires/models/repertoire_authoring.dart',
        'lib/features/repertoires/models/loaded_repertoire.dart',
        'lib/features/repertoires/repositories/repertoire_decoder.dart',
        'lib/features/repertoires/repositories/repertoire_document_repository.dart',
    ])
    pure_roots.extend(path for path in sources if path.startswith(('lib/features/training/models/', 'lib/features/training/repositories/', 'lib/features/generation/models/', 'lib/features/generation/repositories/')))
    errors.extend(pure_dependency_violations(sources, pure_roots))
    ledger = json.loads((root / 'scripts/architecture_feature_debt.json').read_text())
    # Apply the final service-folder boundary from feature state, not a
    # filename allowlist; nested/renamed services in those folders stay covered.
    service_roots = [
        path for path in sources
        if path.startswith('lib/features/')
        and 'services' in Path(path).parts[3:-1]
        and ledger['features'].get(Path(path).parts[2]) in ('enforced', 'complete')
    ]
    domain_roots = [path for path in sources if path.startswith('lib/chess_core/generation/')]
    errors.extend(legacy_service_dependency_violations(sources, service_roots + domain_roots))
    retirements = json.loads((root / 'scripts/architecture_retirements.json').read_text())
    observed_features = {path.name for path in (root / 'lib/features').iterdir() if path.is_dir()}
    feature_findings = []
    for relative, source in sources.items():
        # Retirement cannot be accepted as baseline debt, even in an unfinished
        # feature. Check it independently of the ratchet.
        errors.extend(retirement_violations(relative, source, retirements))
        findings = violations(relative, source, include_retirements=False)
        if relative.startswith('lib/features/'):
            if len(relative.split('/')) < 4:
                errors.append(f'{relative}: feature source must belong to a classified directory')
            feature_findings.extend(findings)
        else:
            errors.extend(findings)
    errors.extend(feature_debt_violations(observed_features, feature_findings, ledger))
    for path in (root / 'widgetbook').rglob('*.dart'):
        errors.extend(violations(path.relative_to(root).as_posix(), path.read_text()))
    legacy = json.loads((root / 'scripts/legacy_theme_consumers.json').read_text())
    observed = set()
    for path in (root / 'lib').rglob('*.dart'):
        relative = path.relative_to(root).as_posix()
        if relative.startswith('lib/theme/'):
            continue
        if any(uri.endswith(('/theme/app_colors.dart', '/theme/app_text_styles.dart', '/theme/pgn_text_styles.dart')) for uri in DIRECTIVE.findall(path.read_text())):
            observed.add(relative)
    for relative in sorted(observed - legacy.keys()):
        errors.append(f'{relative}: new legacy theme consumer; migrate to design_system')
    for relative in sorted(legacy.keys() - observed):
        errors.append(f'{relative}: remove retired consumer from legacy_theme_consumers.json')
    return errors, len(observed_features), len(ledger['baseline'])


def main() -> int:
    errors, feature_count, debt_count = check(ROOT)
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print(f'Renewal architecture boundaries: checked {feature_count} feature directories; '
          f'{debt_count} exact debt entries remain (not completion certification). '
          'Retirement, chess core, infrastructure, design system and catalog gates passed.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
