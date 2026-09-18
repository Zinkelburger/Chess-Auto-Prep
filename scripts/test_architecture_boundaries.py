#!/usr/bin/env python3
"""Regression cases for the migrated dependency gate."""
import json
from pathlib import Path
import tempfile
import unittest

from check_architecture_boundaries import check, legacy_service_dependency_violations, pure_dependency_violations, violations


class BoundariesTest(unittest.TestCase):
    def test_artifact_domain_and_service_reject_hidden_legacy_owners(self):
        for root in ('lib/features/generation/services/artifacts.dart',
                     'lib/chess_core/generation/codec.dart'):
            for directive in ("import '../../services/generation/build_run.dart';",
                              "export '../../services/generation/build_run.dart';",
                              "part '../../services/generation/build_run.dart';",
                              "import 'safe.dart' if (dart.library.io) '../../services/generation/build_run.dart';"):
                sources = {
                    root: "import 'package:chess_auto_prep/utils/hidden/codec.dart';",
                    'lib/utils/hidden/codec.dart': directive,
                }
                with self.subTest(root=root, directive=directive):
                    errors = legacy_service_dependency_violations(sources, [root])
                    self.assertEqual(len(errors), 1)
                    self.assertIn('lib/services/generation/build_run.dart', errors[0])

    def test_artifact_scheduling_stays_outside_pure_codec(self):
        sources = {
            'lib/features/generation/services/artifacts.dart': "import 'dart:isolate';",
            'lib/chess_core/generation/codec.dart': "export 'dart:isolate';",
        }
        self.assertFalse(legacy_service_dependency_violations(sources, list(sources)))
        self.assertEqual(len(pure_dependency_violations(sources, ['lib/chess_core/generation/codec.dart'])), 1)

    def test_composition_scopes_and_riverpod_cannot_return(self):
        for path in ('lib/features/settings/controllers/settings_providers.dart',
                     'lib/features/documents/widgets/stored_game_scope.dart',
                     'lib/features/settings/widgets/display_settings_scope.dart'):
            self.assertTrue(violations(path, "export 'replacement.dart';"))
        for uri in ('package:flutter_riverpod/flutter_riverpod.dart',
                    'package:riverpod/riverpod.dart'):
            for directive in ('import', 'export'):
                self.assertTrue(violations('lib/app/renamed.dart', f"{directive} '{uri}';"))
        for symbol in ('StoredGameScope', 'DisplaySettingsScope', 'repertoireCatalogProvider'):
            self.assertTrue(violations('lib/widgets/renamed.dart', f'class {symbol} {{}}'))

    def test_retired_artifact_libraries_cannot_return_as_forwarding_shims(self):
        for path in ('lib/models/build_tree_node.dart', 'lib/models/trap_line_info.dart',
                     'lib/models/trap_reply.dart', 'lib/services/generation/tree_serialization.dart',
                     'lib/services/eval/eval_canonicalize.dart'):
            self.assertTrue(violations(path, "export 'replacement.dart';"))

    def test_legacy_only_recovery_owner_cannot_return(self):
        for path in ('lib/features/generation/controllers/legacy_analysis_controller.dart',
                     'lib/features/generation/widgets/legacy_analysis_dialog.dart'):
            self.assertTrue(violations(path, "export 'generation_recovery.dart';"))
        for source in ('class LegacyAnalysisController {}', 'repository.exportLegacy(snapshot);',
                       'repository.readLegacy(path);', 'artifacts.inspectLegacy(path);'):
            self.assertTrue(violations('lib/services/renamed_recovery.dart', source))

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

    def test_retired_builder_history_and_append_apis_cannot_return(self):
        for source in ('class AppendMovesResult {}',
                       'editor.appendMoveAtPath(path, move);',
                       'editor.appendMovesAtPath(path, moves);',
                       'authoring.rebuildLine(line);',
                       'save(reconcileInstalled: true);'):
            with self.subTest(source=source):
                self.assertTrue(violations('lib/services/renamed_writer.dart', source))

    def test_retired_builder_libraries_cannot_return_as_forwarding_shims(self):
        for path in ('lib/core/repertoire_controller.dart', 'lib/core/repertoire_writer.dart',
                     'lib/core/repertoire_authoring.dart', 'lib/core/move_navigation.dart',
                     'lib/services/repertoire_line_expansion.dart', 'lib/services/course_chapter_headers.dart'):
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
        for path in ('lib/features/repertoires/controllers/builder_workspace_controller.dart', 'lib/features/repertoires/controllers/repertoire_writer.dart'):
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


class FeatureDebtGateTest(unittest.TestCase):
    """Exercise the real repository scan against small production-shaped trees."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.owner = 'lib/features/tactics/controllers/session.dart'
        self.debt = f'{self.owner}: forbidden dependency dart:io'
        self.ledger = {'features': {'tactics': 'unfinished'}, 'baseline': [self.debt]}
        self.write(self.owner, "import 'dart:io';")
        self.write_json('scripts/legacy_theme_consumers.json', {})
        self.write_json('scripts/architecture_retirements.json', {
            'paths': ['lib/core/pgn/', 'lib/features/documents/controllers/pgn_viewer_controller.dart'],
            'symbols': ['PgnViewerController'],
        })

    def write(self, path, source):
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(source)

    def write_json(self, path, data):
        self.write(path, json.dumps(data))

    def errors(self):
        self.write_json('scripts/architecture_feature_debt.json', self.ledger)
        return check(self.root)[0]

    def test_enforced_service_gate_selects_new_owner_paths_and_hidden_dependencies(self):
        self.write(self.owner, 'class Session {}')
        self.ledger['baseline'].clear()
        self.write('lib/utils/codec.dart', "export '../services/hidden.dart';")
        for state in ('enforced', 'complete'):
            self.ledger['features']['tactics'] = state
            for name in ('artifacts.dart', 'renamed.dart'):
                path = f'lib/features/tactics/services/nested/{name}'
                self.write(path, "import 'package:chess_auto_prep/utils/codec.dart';")
                errors = self.errors()
                self.assertTrue(any(path + ': legacy service dependency chain' in error for error in errors))
                (self.root / path).unlink()
        self.write('lib/chess_core/generation/new_codec.dart', "import '../../utils/codec.dart';")
        self.assertTrue(any('new_codec.dart: legacy service dependency chain' in error for error in self.errors()))

    def test_existing_debt_is_visible_but_a_new_dependency_fails(self):
        self.assertEqual(self.errors(), [])
        self.write(self.owner, "import 'dart:io';\nimport 'dart:ffi';")
        self.assertTrue(any('dart:ffi [new violation' in error for error in self.errors()))

    def test_unknown_directory_is_rejected_even_when_empty_or_clean(self):
        (self.root / 'lib/features/new_domain').mkdir()
        self.assertTrue(any('new_domain/: unclassified' in error for error in self.errors()))
        self.write('lib/features/new_domain/models/state.dart', 'class State {}')
        self.assertTrue(any('new_domain/: unclassified' in error for error in self.errors()))
        self.ledger['features']['new_domain'] = 'enforced'
        self.assertEqual(self.errors(), [])

    def test_loose_feature_source_cannot_avoid_classification(self):
        self.write('lib/features/loose.dart', 'class Session {}')
        self.assertTrue(any('must belong to a classified directory' in error for error in self.errors()))

    def test_removed_violation_requires_baseline_to_shrink(self):
        self.write(self.owner, "import '../repositories/port.dart';")
        self.assertTrue(any('stale baseline' in error for error in self.errors()))
        self.ledger['baseline'].clear()
        self.assertEqual(self.errors(), [])
        self.write(self.owner, "import 'dart:io';")
        self.assertTrue(any('new violation' in error for error in self.errors()))

    def test_completed_and_enforced_features_cannot_keep_debt(self):
        for state in ('enforced', 'complete'):
            self.ledger['features']['tactics'] = state
            self.assertTrue(any('only unfinished' in error for error in self.errors()))
        self.ledger['baseline'].clear()
        self.write(self.owner, 'class Session {}')
        self.assertEqual(self.errors(), [])

    def test_deleted_feature_requires_both_classification_and_debt_removal(self):
        (self.root / self.owner).unlink()
        (self.root / 'lib/features/tactics/controllers').rmdir()
        (self.root / 'lib/features/tactics').rmdir()
        errors = self.errors()
        self.assertTrue(any('stale feature classification' in error for error in errors))
        self.assertTrue(any('stale baseline' in error for error in errors))

    def test_singleton_baseline_does_not_exempt_other_calls_in_same_file(self):
        line = 'final engine = Engine.instance;'
        self.write(self.owner, line)
        self.ledger['baseline'] = [f'{self.owner}: global singleton access bypasses injection: {line}']
        self.assertEqual(self.errors(), [])
        self.write(self.owner, line + '\nfinal storage = Storage.instance;')
        self.assertTrue(any('Storage.instance' in error and 'new violation' in error for error in self.errors()))
        # Duplicating an existing violation must not hide behind set equality.
        self.write(self.owner, line + '\n' + line)
        self.assertTrue(any('new violation' in error for error in self.errors()))

    def test_theme_baseline_does_not_exempt_new_appearance_debt(self):
        (self.root / self.owner).unlink()
        path = 'lib/features/tactics/widgets/panel.dart'
        line = 'final color = Colors.red;'
        self.write(path, line)
        self.ledger['baseline'] = [f'{path}: widget bypasses active theme/typography: {line}']
        self.assertEqual(self.errors(), [])
        self.write(path, line + '\nfinal style = TextStyle(fontSize: 12);')
        self.assertTrue(any('fontSize' in error and 'new violation' in error for error in self.errors()))

    def test_retirement_cannot_be_baselined_or_hidden_by_path_move(self):
        self.write(self.owner, 'PgnViewerController? owner;')
        self.ledger['baseline'] = [f'{self.owner}: retired API PgnViewerController; use its final owner']
        self.assertTrue(any('retired API' in error for error in self.errors()))
        self.ledger['baseline'].clear()
        self.write(self.owner, 'class Session {}')
        self.write('lib/services/renamed.dart', 'final owner = PgnViewerController.create();')
        self.assertTrue(any('renamed.dart: retired API' in error for error in self.errors()))

    def test_retired_forwarder_or_reference_is_rejected(self):
        self.write('lib/core/pgn/shim.dart', "export '../../features/documents/models/document.dart';")
        self.assertTrue(any('shim.dart: retired library' in error for error in self.errors()))
        (self.root / 'lib/core/pgn/shim.dart').unlink()
        self.write(self.owner, "import '../../../core/pgn/shim.dart';")
        self.assertTrue(any('dependency on retired library' in error for error in self.errors()))

    def test_retired_names_in_comments_are_not_consumers(self):
        self.write(self.owner, "// PgnViewerController was deleted.\n/* PgnViewerController */")
        self.ledger['baseline'].clear()
        self.assertEqual(self.errors(), [])

    def test_retired_constructor_inside_interpolation_still_fails(self):
        self.write(self.owner, "final message = '${PgnViewerController()}';")
        self.ledger['baseline'].clear()
        self.assertTrue(any('retired API' in error for error in self.errors()))

    def test_conditional_import_cannot_hide_new_native_dependency(self):
        self.write(self.owner, "import 'port.dart' if (dart.library.io) 'dart:io';")
        self.ledger['baseline'].clear()
        self.assertTrue(any('forbidden dependency dart:io' in error for error in self.errors()))

    def test_normalized_package_import_cannot_hide_infrastructure(self):
        self.write(self.owner, "import 'package:chess_auto_prep/features/tactics/../../infrastructure/store.dart';")
        self.ledger['baseline'].clear()
        self.assertTrue(any('forbidden dependency' in error for error in self.errors()))

    def test_stale_or_nonfeature_baseline_is_not_an_exemption(self):
        self.ledger['baseline'].append('lib/services/legacy.dart: forbidden dependency dart:io')
        self.assertTrue(any('only feature findings' in error for error in self.errors()))
        self.ledger['features']['tactics'] = 'migrated-ish'
        self.assertTrue(any('invalid feature state' in error for error in self.errors()))


if __name__ == '__main__':
    unittest.main()
