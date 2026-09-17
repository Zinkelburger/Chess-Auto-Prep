#!/usr/bin/env python3
"""Regression cases for the migrated dependency gate."""
import unittest

from check_architecture_boundaries import RETIRED_BUILDER_LIBRARIES, pure_dependency_violations, violations


class BoundariesTest(unittest.TestCase):
    def test_training_and_generation_owners_cannot_reintroduce_io(self):
        for feature in ('training', 'generation'):
            for layer in ('controllers', 'models', 'repositories'):
                path = f'lib/features/{feature}/{layer}/owner.dart'
                for uri in ('dart:io', 'package:shared_preferences/shared_preferences.dart',
                            'package:chess_auto_prep/infrastructure/storage.dart',
                            '../../../services/storage/storage_factory.dart'):
                    with self.subTest(path=path, uri=uri):
                        self.assertTrue(violations(path, f"import '{uri}';"))
                self.assertTrue(violations(path, 'final store = StorageFactory.instance;'))
                self.assertFalse(violations(path, "import '../repositories/port.dart';"))

    def test_retired_training_and_generation_writers_stay_retired(self):
        self.assertTrue(violations('lib/services/training/phase.dart', "export 'new_owner.dart';"))
        self.assertTrue(violations('lib/models/training_settings.dart', "export 'new_owner.dart';"))
        self.assertTrue(violations('lib/services/generation/pgn_export.dart', 'class PgnBatchWriter {}'))
        self.assertTrue(violations('lib/core/generation_session_controller.dart', 'final writer = PgnBatchWriter();'))

    def test_retired_builder_libraries_cannot_return_as_forwarding_shims(self):
        for path in RETIRED_BUILDER_LIBRARIES:
            self.assertTrue(violations(path, "export 'replacement.dart';"))

    def test_retired_viewer_libraries_cannot_return_as_forwarding_shims(self):
        for path in ('lib/core/pgn/workspace.dart', 'lib/core/pgn_viewer_controller.dart', 'lib/services/pgn_opening_headers.dart'):
            self.assertTrue(violations(path, "export 'replacement.dart';"))

    def test_pure_dependency_gate_follows_transitive_exports(self):
        sources = {
            'lib/chess_core/root.dart': "import '../utils/cache.dart';",
            'lib/utils/cache.dart': "export 'hidden.dart';",
            'lib/utils/hidden.dart': "import 'package:flutter/foundation.dart';",
        }
        errors = pure_dependency_violations(sources, ['lib/chess_core/root.dart'])
        self.assertEqual(len(errors), 1)
        self.assertIn('lib/utils/hidden.dart -> package:flutter/foundation.dart', errors[0])

    def test_pure_dependency_gate_handles_cycles_and_ignores_unrelated_ui(self):
        sources = {
            'lib/chess_core/root.dart': "import 'package:chess_auto_prep/chess_core/leaf.dart';",
            'lib/chess_core/leaf.dart': "import 'root.dart';\nimport 'package:meta/meta.dart';",
            'lib/widgets/ui.dart': "import 'package:flutter/widgets.dart';",
        }
        self.assertFalse(pure_dependency_violations(sources, ['lib/chess_core/root.dart']))

    def test_pure_dependency_gate_checks_parts_and_conditional_branches(self):
        sources = {
            'lib/chess_core/root.dart': "import 'safe.dart' if (dart.library.io) 'native.dart';\npart 'part.dart';",
            'lib/chess_core/safe.dart': '',
            'lib/chess_core/native.dart': "import 'dart:io';",
            'lib/chess_core/part.dart': "import 'dart:ui';",
        }
        errors = pure_dependency_violations(sources, ['lib/chess_core/root.dart'])
        self.assertEqual(len(errors), 2)

    def test_single_game_parser_boundary_also_covers_legacy_consumers(self):
        direct = 'final game = PgnGame.parsePgn(text);'
        self.assertTrue(violations('lib/services/legacy.dart', direct))
        self.assertFalse(violations('lib/chess_core/pgn/pgn_parser.dart', direct))
        self.assertFalse(violations('lib/services/legacy.dart', 'final game = parsePgnGame(text);'))
        self.assertFalse(violations('lib/services/legacy.dart', '/// PgnGame.parsePgn(text) is the reference.'))

    def test_frame_scheduling_is_only_allowed_in_feature_widgets(self):
        frame = 'WidgetsBinding.instance.addPostFrameCallback(callback);'
        self.assertFalse(violations('lib/features/documents/widgets/viewport.dart', frame))
        self.assertTrue(violations('lib/features/documents/controllers/session.dart', frame))
        self.assertTrue(violations('lib/features/documents/widgets/viewport.dart', 'Engine.instance.start();'))

    def test_builder_hosts_use_injected_document_boundaries(self):
        for path in ('lib/features/repertoires/controllers/repertoire_controller.dart', 'lib/features/repertoires/controllers/repertoire_writer.dart'):
            for uri in ('dart:io', 'dart:isolate', '../services/storage/storage_factory.dart', '../services/repertoire_file_editor.dart', '../infrastructure/repertoires/store.dart'):
                self.assertTrue(violations(path, f"import '{uri}';"))
            self.assertTrue(violations(path, 'StorageFactory.instance.readFile(path);'))
            self.assertFalse(violations(path, "import '../features/repertoires/repositories/repertoire_document_repository.dart';"))

    def test_models_and_contracts_stay_pure(self):
        for area in ('models', 'repositories'):
            path = f'lib/features/repertoires/{area}/example.dart'
            for uri in ('dart:io', 'package:flutter/widgets.dart', 'package:flutter_riverpod/flutter_riverpod.dart', 'dart:ffi', 'package:document_file_io/document_file_io.dart'):
                with self.subTest(area=area, uri=uri):
                    self.assertTrue(violations(path, f"import '{uri}';"))

    def test_controller_cannot_bypass_domain(self):
        path = 'lib/features/repertoires/controllers/example.dart'
        for uri in ('../../../services/storage/storage_factory.dart', 'package:chess_auto_prep/infrastructure/storage.dart', '../widgets/editor.dart'):
            with self.subTest(uri=uri):
                self.assertTrue(violations(path, f"import '{uri}';"))
        self.assertTrue(violations(path, 'final store = StorageFactory.instance;'))

    def test_studies_and_chess_core_boundaries(self):
        for uri in ('../../../services/storage/storage_factory.dart', '../widgets/editor.dart', '../../../infrastructure/store.dart'):
            self.assertTrue(violations('lib/features/studies/controllers/editor.dart', f"import '{uri}';"))
        for uri in ('dart:io', 'package:flutter/widgets.dart', '../../services/parser.dart'):
            self.assertTrue(violations('lib/chess_core/pgn/text.dart', f"import '{uri}';"))
        self.assertFalse(violations('lib/features/studies/controllers/editor.dart', "import '../../documents/controllers/document_save_session.dart';"))

    def test_settings_cannot_access_preferences_directly(self):
        self.assertTrue(violations('lib/features/settings/repositories/settings.dart', "import 'package:shared_preferences/shared_preferences.dart';"))

    def test_export_is_not_a_backdoor(self):
        self.assertTrue(violations('lib/features/repertoires/models/example.dart', "export 'dart:io';"))

    def test_infrastructure_cannot_own_presentation(self):
        self.assertTrue(violations('lib/infrastructure/repertoires/store.dart', "import '../../features/repertoires/controllers/editor.dart';"))

    def test_localization_stays_in_presentation(self):
        for path in (
            'lib/features/repertoires/models/state.dart',
            'lib/features/repertoires/controllers/catalog.dart',
            'lib/infrastructure/repertoires/store.dart',
        ):
            with self.subTest(path=path):
                self.assertTrue(violations(path, "import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';"))
        self.assertFalse(violations('lib/features/repertoires/widgets/catalog.dart', "import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';"))

    def test_appearance_widgets_use_active_theme(self):
        path = 'lib/features/settings/widgets/appearance.dart'
        self.assertTrue(violations(path, "import '../../../theme/app_colors.dart';"))
        self.assertTrue(violations(path, 'const TextStyle(fontSize: 14);'))
        self.assertFalse(violations(path, 'Theme.of(context).colorScheme.onSurface;'))

    def test_document_save_widgets_use_active_theme(self):
        self.assertTrue(violations('lib/features/documents/widgets/save.dart', "import '../../../theme/app_colors.dart';"))
        self.assertTrue(violations('lib/features/documents/widgets/save.dart', 'const TextStyle(fontSize: 14);'))
        self.assertFalse(violations('lib/features/documents/widgets/save.dart', "import '../../../design_system/components/save_status.dart';"))

    def test_design_system_has_no_app_or_domain_dependencies(self):
        for uri in ('../../features/repertoires/models/repertoire_metadata.dart', '../../theme/app_colors.dart', 'dart:io'):
            self.assertTrue(violations('lib/design_system/components/example.dart', f"import '{uri}';"))
        self.assertFalse(violations('lib/design_system/components/example.dart', "import '../theme/app_typography.dart';"))

    def test_migrated_widgets_resolve_theme_roles(self):
        path = 'lib/features/repertoires/widgets/example.dart'
        for source in ("import '../../../theme/app_colors.dart';", 'final color = Color(0xff121212);', 'final style = TextStyle(fontSize: 14);'):
            self.assertTrue(violations(path, source))
        self.assertFalse(violations(path, 'final color = Theme.of(context).colorScheme.error;'))

    def test_widgetbook_cannot_initialize_real_storage(self):
        for source in ("import 'dart:io';", "import 'package:chess_auto_prep/services/storage/storage_factory.dart';", 'final repo = StorageFactory.instance;'):
            self.assertTrue(violations('widgetbook/cases.dart', source))

    def test_injected_domain_dependencies_are_allowed(self):
        self.assertFalse(violations('lib/features/repertoires/controllers/example.dart', "import '../repositories/repertoire_catalog_repository.dart';"))
        self.assertFalse(violations('lib/infrastructure/repertoires/store.dart', "import '../../features/repertoires/repositories/repertoire_catalog_repository.dart';"))


if __name__ == '__main__':
    unittest.main()
