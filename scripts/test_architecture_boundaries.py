#!/usr/bin/env python3
"""Regression cases for the migrated dependency gate."""
import unittest

from check_architecture_boundaries import violations


class BoundariesTest(unittest.TestCase):
    def test_models_and_contracts_stay_pure(self):
        for area in ('models', 'repositories'):
            path = f'lib/features/repertoires/{area}/example.dart'
            for uri in ('dart:io', 'package:flutter/widgets.dart', 'package:flutter_riverpod/flutter_riverpod.dart'):
                with self.subTest(area=area, uri=uri):
                    self.assertTrue(violations(path, f"import '{uri}';"))

    def test_controller_cannot_bypass_domain(self):
        path = 'lib/features/repertoires/controllers/example.dart'
        for uri in ('../../../services/storage/storage_factory.dart', 'package:chess_auto_prep/infrastructure/storage.dart', '../widgets/editor.dart'):
            with self.subTest(uri=uri):
                self.assertTrue(violations(path, f"import '{uri}';"))
        self.assertTrue(violations(path, 'final store = StorageFactory.instance;'))

    def test_export_is_not_a_backdoor(self):
        self.assertTrue(violations('lib/features/repertoires/models/example.dart', "export 'dart:io';"))

    def test_infrastructure_cannot_own_presentation(self):
        self.assertTrue(violations('lib/infrastructure/repertoires/store.dart', "import '../../features/repertoires/controllers/editor.dart';"))

    def test_injected_domain_dependencies_are_allowed(self):
        self.assertFalse(violations('lib/features/repertoires/controllers/example.dart', "import '../repositories/repertoire_catalog_repository.dart';"))
        self.assertFalse(violations('lib/infrastructure/repertoires/store.dart', "import '../../features/repertoires/repositories/repertoire_catalog_repository.dart';"))


if __name__ == '__main__':
    unittest.main()
