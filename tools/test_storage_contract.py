#!/usr/bin/env python3
"""Version-independent identity is part of the storage upgrade contract."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StorageIdentityTest(unittest.TestCase):
    def test_linux_application_identity_is_stable(self):
        self.assertIn('set(APPLICATION_ID "com.example.chess_auto_prep")', (ROOT / 'linux/CMakeLists.txt').read_text())
        self.assertIn('set(BINARY_NAME "chess_auto_prep")', (ROOT / 'linux/CMakeLists.txt').read_text())

    def test_windows_path_provider_identity_is_stable(self):
        resource = (ROOT / 'windows/runner/Runner.rc').read_text()
        self.assertIn('VALUE "CompanyName", "com.example"', resource)
        self.assertIn('VALUE "ProductName", "Chess Auto Prep"', resource)
        installer = (ROOT / 'packaging/windows/installer.iss').read_text()
        self.assertIn('AppId={{B7E0C2A4-5D3F-4E6B-9C8A-1F2D3E4C5B6A}', installer)
        self.assertIn('PrivilegesRequired=lowest', installer)
        # Install/uninstall must never own document or profile directories.
        for location in ['{userdocs}', '{userappdata}', '{commonappdata}']:
            self.assertNotIn(location, installer.lower())

    def test_legacy_document_layout_remains_addressable(self):
        paths = (ROOT / 'lib/services/storage/app_paths.dart').read_text()
        for name in ['repertoires', 'analysis_games', 'pgn_collections', 'games_library',
                     'tactics_sets', 'studies', 'engine_tournaments', 'opponents']:
            self.assertIn(f"= '{name}';", paths)
        self.assertIn('return getApplicationDocumentsDirectory();', paths)
        self.assertIn('return getApplicationSupportDirectory();', paths)


if __name__ == '__main__':
    unittest.main()
