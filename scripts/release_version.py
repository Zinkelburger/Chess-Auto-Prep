#!/usr/bin/env python3
"""Resolve the release's artifact version before starting any expensive jobs."""
import os
from pathlib import Path
import re

from release_assets import expected_assets


def candidate_tag(pubspec, event, ref):
    versions = re.findall(r'^version:\s*(\S+)', pubspec, re.M)
    if len(versions) != 1:
        raise ValueError('Expected one version in pubspec.yaml')
    tag = f'v{versions[0]}'
    expected_assets(tag)  # Apply the same filename rules as final staging.
    if event == 'push' and ref.startswith('refs/tags/'):
        if ref != f'refs/tags/{tag}':
            raise ValueError(f'Release tag must match pubspec.yaml: expected {tag}, got {ref}')
    elif event != 'workflow_dispatch' and (event, ref) != ('push', 'refs/heads/release-check'):
        raise ValueError(f'Unsupported release event: {event} {ref}')
    return tag


def main():
    tag = candidate_tag(Path('pubspec.yaml').read_text(),
                        os.environ['GITHUB_EVENT_NAME'], os.environ['GITHUB_REF'])
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'tag={tag}\n')
    print(f'Candidate: {tag} at {os.environ["GITHUB_SHA"]}')


if __name__ == '__main__':
    main()
