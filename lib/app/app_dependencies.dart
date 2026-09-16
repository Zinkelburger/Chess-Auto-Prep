import 'dart:io';
import '../infrastructure/documents/native_pgn_document_store.dart';
import '../features/documents/repositories/pgn_document_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/repertoires/controllers/repertoire_catalog_controller.dart';
import '../features/repertoires/repositories/repertoire_catalog_repository.dart';
import '../infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import '../services/storage/storage_factory.dart';
import '../services/storage/io_storage_service.dart';
import '../features/settings/controllers/settings_providers.dart';
import '../features/settings/repositories/app_settings_repository.dart';
import '../infrastructure/settings/shared_preferences_app_settings_repository.dart';

/// Composition root for migrated features. Legacy Provider owners remain under
/// this scope until their own feature migrates; they never own catalog state.
class AppDependencies extends StatefulWidget {
  const AppDependencies({
    super.key,
    required this.child,
    this.repertoireCatalog,
    this.documentStore,
    this.settings,
  });

  final Widget child;
  final RepertoireCatalogRepository? repertoireCatalog;
  final PgnDocumentStore? documentStore;
  final AppSettingsRepository? settings;

  @override
  State<AppDependencies> createState() => _AppDependenciesState();
}

class _AppDependenciesState extends State<AppDependencies> {
  late final _defaultCatalog = LegacyRepertoireCatalogRepository(
    StorageFactory.instance,
    documents: widget.documentStore,
  );

  @override
  Widget build(BuildContext context) => ProviderScope(
    retry: (count, error) => null,
    overrides: [
      appSettingsRepositoryProvider.overrideWithValue(
        widget.settings ?? SharedPreferencesAppSettingsRepository.instance,
      ),
      repertoireCatalogRepositoryProvider.overrideWithValue(
        widget.repertoireCatalog ?? _defaultCatalog,
      ),
    ],
    child: widget.child,
  );
}

/// Adopt only on the verified host; the remaining native commit protocols
/// keep their documented legacy adapter until their platform gates pass.
PgnDocumentStore? createPlatformDocumentStore() {
  if (!Platform.isLinux) return null;
  final storage = StorageFactory.instance;
  return NativePgnDocumentStore(
    guardOperation: storage is IOStorageService
        ? storage.guardDocumentOperation
        : null,
  );
}
