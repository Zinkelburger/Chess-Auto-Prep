#!/usr/bin/env python3
"""Offline tests for the parsers in outdated_deps.py."""
import unittest

from outdated_deps import (parse_action_pins, parse_pub_outdated,
                           parse_requirements, version_key)


class OutdatedDepsTest(unittest.TestCase):
    def test_pub_rows_skip_current_and_missing_versions(self):
        report = {'packages': [
            {'package': 'path', 'kind': 'direct', 'current': {'version': '1.0.0'},
             'resolvable': {'version': '1.1.0'}, 'latest': {'version': '2.0.0'}},
            {'package': 'same', 'kind': 'direct', 'current': {'version': '1.0.0'},
             'latest': {'version': '1.0.0'}},
            {'package': 'gone', 'kind': 'transitive', 'current': None,
             'latest': {'version': '3.0.0'}},
        ]}
        self.assertEqual(parse_pub_outdated(report),
                         [('path', 'direct', '1.0.0', '1.1.0', '2.0.0')])

    def test_requirements_keep_name_operator_and_version(self):
        text = '# tools\npython-chess>=1.11.2\npydantic[email]>=2.0.0\nrequests==2.31  # pin\n-e .\n'
        self.assertEqual(parse_requirements(text), [
            ('python-chess', '>=', '1.11.2'), ('pydantic', '>=', '2.0.0'),
            ('requests', '==', '2.31')])

    def test_action_pins_read_sha_and_version_comment(self):
        sha = 'a' * 40
        text = (f'      - uses: actions/checkout@{sha} # v7\n'
                f'      - uses: github/codeql-action/init@{sha}\n'
                '      - uses: ./.github/workflows/ci.yml\n')
        self.assertEqual(parse_action_pins(text), {
            'actions/checkout': (sha, 'v7'), 'github/codeql-action': (sha, '')})

    def test_version_key_orders_tags_numerically(self):
        self.assertGreater(version_key('v10.0.1'), version_key('v9.9'))
        self.assertEqual(version_key('v7'), (7,))


if __name__ == '__main__':
    unittest.main()
