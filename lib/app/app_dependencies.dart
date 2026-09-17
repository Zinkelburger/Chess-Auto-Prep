import 'dart:io';
import 'package:provider/provider.dart' as legacy_provider;
import 'training_dependencies.dart';
import '../features/training/repositories/training_settings_repository.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/documents/repositories/desktop_fullscreen_port.dart';
import '../features/documents/repositories/pgn_collection_decoder.dart';
import '../features/documents/repositories/pgn_collection_filter.dart';
import '../features/documents/repositories/pgn_collection_repository.dart';
import '../features/documents/repositories/pgn_document_store.dart';
import '../features/documents/repositories/pgn_library_repository.dart';
import '../features/documents/repositories/stored_game_repository.dart';
import '../features/documents/repositories/viewer_preferences_repository.dart';
import '../features/documents/widgets/stored_game_scope.dart';
import '../features/repertoires/controllers/repertoire_catalog_controller.dart';
import '../features/repertoires/repositories/repertoire_catalog_repository.dart';
import '../features/settings/controllers/settings_providers.dart';
import '../features/settings/repositories/app_settings_repository.dart';
import '../infrastructure/desktop/window_fullscreen_adapter.dart';
import '../infrastructure/documents/archive_stored_game_repository.dart';
import '../infrastructure/documents/isolate_pgn_collection_decoder.dart';
import '../infrastructure/documents/isolate_pgn_collection_filter.dart';
import '../infrastructure/documents/native_pgn_document_store.dart';
import '../infrastructure/documents/shared_preferences_viewer_repository.dart';
import '../infrastructure/documents/storage_pgn_collection_repository.dart';
import '../infrastructure/documents/storage_pgn_library_repository.dart';
import '../infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import '../infrastructure/settings/shared_preferences_app_settings_repository.dart';
import '../services/default_pgn_service.dart';
import '../services/game_store/game_store_service.dart';
import '../services/storage/io_storage_service.dart';
import '../services/storage/storage_factory.dart';

/// Composition root for migrated features. Legacy Provider owners remain under
/// this scope until their own feature migrates; they never own catalog state.
class AppDependencies extends StatefulWidget {
  const AppDependencies({
    super.key,
    required this.child,
    this.repertoireCatalog,
    this.documentStore,
    this.settings,
    this.storedGames,
    this.trainingSettings,
  });

  final Widget child;
  final RepertoireCatalogRepository? repertoireCatalog;
  final PgnDocumentStore? documentStore;
  final AppSettingsRepository? settings;
  final StoredGameRepository? storedGames;
  final TrainingSettingsRepository? trainingSettings;

  @override
  State<AppDependencies> createState() => _AppDependenciesState();
}

class _AppDependenciesState extends State<AppDependencies> {
  late final _trainingSettings = createTrainingSettings();

  @override
  void dispose() {
    _trainingSettings.dispose();
    super.dispose();
  }

  late final _storedGames = ArchiveStoredGameRepository(
    GameStoreService.instance.open,
  );

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
    child: StoredGameScope(
      repository: widget.storedGames ?? _storedGames,
      child: legacy_provider.Provider<TrainingSettingsRepository>.value(
        value: widget.trainingSettings ?? _trainingSettings,
        child: widget.child,
      ),
    ),
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

PgnCollectionRepository createPgnCollectionRepository({
  required PgnDocumentStore? documents,
}) => StoragePgnCollectionRepository(
  StorageFactory.instance,
  documents: documents,
);

ViewerPreferencesRepository createViewerPreferencesRepository() =>
    SharedPreferencesViewerRepository(SharedPreferences.getInstance);

PgnCollectionDecoder createPgnCollectionDecoder() =>
    const IsolatePgnCollectionDecoder();

PgnLibraryRepository createPgnLibraryRepository() =>
    StoragePgnLibraryRepository(
      StorageFactory.instance,
      directory: () => DefaultPgnService.collectionsPath,
    );

PgnCollectionFilter createPgnCollectionFilter() =>
    const IsolatePgnCollectionFilter();

DesktopFullscreenPort createViewerWindowPort() => WindowFullscreenAdapter();
