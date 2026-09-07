#!/usr/bin/env python3
"""Generate thin native rule references; --check verifies without writing."""
import argparse
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent

# Policy lives in AGENTS.md and docs/agents/*.md, never in these adapters.
SCOPES = {
    'dart': ('Dart code conventions', ('**/*.dart',)),
    'ui': ('Flutter UI conventions', (
        'lib/widgets/**/*.dart', 'lib/screens/**/*.dart',
        'lib/features/*/widgets/**/*.dart', 'lib/theme/**/*.dart',
        'test/widgets/**/*.dart', 'test/screens/**/*.dart',
        'test/features/*/widgets/**/*.dart',
        'integration_test/**/*.dart',
    )),
    'documentation': ('App documentation changes', ('docs/**/*.md',)),
}
RETIRED = (
    '.cursor/rules/agent-workflow.mdc',
    '.cursor/rules/app-documentation.mdc',
    '.cursor/rules/cross-platform-paths.mdc',
    '.cursor/rules/flutter-mounted-guard.mdc',
    '.cursor/rules/shortcut-tooltips.mdc',
)


def adapters():
    result = {'CLAUDE.md': '@AGENTS.md\n'}
    for name, (description, patterns) in SCOPES.items():
        source = f'docs/agents/{name}.md'
        result[f'.cursor/rules/{name}.mdc'] = (
            f'---\ndescription: {description}\n'
            f'globs: {", ".join(patterns)}\nalwaysApply: false\n---\n\n'
            f'@{source}\n'
        )
        paths = ''.join(f'  - "{pattern}"\n' for pattern in patterns)
        result[f'.claude/rules/{name}.md'] = (
            f'---\npaths:\n{paths}---\n\n@../../{source}\n'
        )
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    errors = []
    for relative, expected in adapters().items():
        path = ROOT / relative
        if args.check:
            if not path.is_file() or path.read_text() != expected:
                errors.append(f'{relative}: run python3 scripts/sync_agent_rules.py')
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(expected)
    # Never silently delete a hand-edited retired rule.
    for relative in RETIRED:
        if (ROOT / relative).exists():
            errors.append(f'{relative}: retired rule still exists; review and remove it')
    for name in (*SCOPES, 'tooling', 'git', 'README'):
        if not (ROOT / f'docs/agents/{name}.md').is_file():
            errors.append(f'missing docs/agents/{name}.md')
    root_policy = ROOT / 'AGENTS.md'
    if not root_policy.is_file():
        errors.append('missing AGENTS.md')
    elif len(root_policy.read_text().splitlines()) > 120:
        errors.append('AGENTS.md exceeds 120 lines; move task-specific detail to a guide')
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print('Agent rule references and root size: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
