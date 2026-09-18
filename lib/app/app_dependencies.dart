import 'engine_runtime.dart';
import '../services/engine/board_engine.dart';
import '../services/engine/engine_lifecycle.dart';
import '../services/engine/engine_search_budget.dart';
import '../services/engine/generation_lease.dart';
import '../services/engine/stockfish_pool.dart';
import 'dart:async';
import 'runtime_settings.dart';
import '../features/settings/controllers/engine_settings.dart';
import '../features/settings/controllers/bulk_analysis_settings.dart';
import '../features/settings/controllers/board_display_settings.dart';
import '../features/settings/models/app_appearance.dart';
import '../features/settings/models/settings_state.dart';
import 'dart:io';
import 'package:provider/provider.dart';
import 'training_dependencies.dart';
import '../features/training/repositories/training_settings_repository.dart';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/documents/repositories/desktop_fullscreen_port.dart';
import '../features/documents/repositories/pgn_collection_decoder.dart';
import '../features/documents/repositories/pgn_collection_filter.dart';
import '../features/documents/repositories/pgn_collection_repository.dart';
import '../features/documents/repositories/pgn_document_store.dart';
import '../features/documents/repositories/pgn_library_repository.dart';
import '../features/documents/repositories/stored_game_repository.dart';
import '../features/documents/repositories/viewer_preferences_repository.dart';
import '../features/repertoires/controllers/repertoire_catalog_controller.dart';
import '../features/repertoires/repositories/repertoire_catalog_repository.dart';
import '../features/settings/repositories/app_settings_repository.dart';
import '../infrastructure/desktop/window_fullscreen_adapter.dart';
import '../infrastructure/documents/archive_stored_game_repository.dart';
import '../infrastructure/documents/legacy_pgn_document_store.dart';
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

/// App-owned dependencies use constructors and one Provider tree.
class AppDependencies extends StatefulWidget {
  const AppDependencies({
    super.key,
    required this.child,
    this.repertoireCatalog,
    this.documentStore,
    this.settings,
    this.storedGames,
    this.trainingSettings,
    this.runtimeSettings,
    this.engineRuntime,
  });

  final Widget child;
  final RepertoireCatalogRepository? repertoireCatalog;
  final PgnDocumentStore? documentStore;
  final AppSettingsRepository? settings;
  final StoredGameRepository? storedGames;
  final TrainingSettingsRepository? trainingSettings;
  final RuntimeSettings? runtimeSettings;
  final EngineRuntime? engineRuntime;

  @override
  State<AppDependencies> createState() => _AppDependenciesState();
}

class _AppDependenciesState extends State<AppDependencies> {
  late final _runtime = widget.runtimeSettings ?? RuntimeSettings.preferences();
  late final _engines =
      widget.engineRuntime ?? EngineRuntime(settings: _runtime.engine);
  @override
  void initState() {
    super.initState();
    unawaited(_runtime.load());
    if (widget.engineRuntime == null) {
      unawaited(
        _engines.lifecycle.loadPersistedState().catchError((Object _) {}),
      );
    }
  }

  late final _trainingSettings = createTrainingSettings();

  @override
  void dispose() {
    _trainingSettings.dispose();
    _engines.dispose();
    _runtime.dispose();
    super.dispose();
  }

  late final _storedGames = ArchiveStoredGameRepository(
    GameStoreService.instance.open,
  );

  late final _defaultCatalog = LegacyRepertoireCatalogRepository(
    StorageFactory.instance,
    documents: widget.documentStore ?? createPlatformDocumentStore(),
  );

  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      Provider<RepertoireCatalogRepository>.value(
        value: widget.repertoireCatalog ?? _defaultCatalog,
      ),
      ChangeNotifierProvider(
        key: ObjectKey(widget.repertoireCatalog ?? _defaultCatalog),
        create: (context) => RepertoireCatalogController(
          context.read<RepertoireCatalogRepository>(),
        ),
      ),
      Provider<AppearanceRepository>.value(
        value:
            (widget.settings ?? SharedPreferencesAppSettingsRepository.instance)
                .appearance,
      ),
      StreamProvider<SettingsState<AppAppearance>>(
        key: ObjectKey(
          (widget.settings ?? SharedPreferencesAppSettingsRepository.instance)
              .appearance,
        ),
        initialData:
            (widget.settings ?? SharedPreferencesAppSettingsRepository.instance)
                .appearance
                .state,
        create: (context) {
          final appearance = context.read<AppearanceRepository>();
          return Stream.multi((controller) {
            final subscription = appearance.changes.listen(controller.addSync);
            controller.addSync(appearance.state);
            controller.onCancel = subscription.cancel;
            unawaited(appearance.ensureLoaded().catchError((Object _) {}));
          });
        },
      ),
      Provider<StoredGameRepository>.value(
        value: widget.storedGames ?? _storedGames,
      ),
      Provider<TrainingSettingsRepository>.value(
        value: widget.trainingSettings ?? _trainingSettings,
      ),
      Provider<BoardEngine>.value(value: _engines.board),
      Provider<StockfishPool>.value(value: _engines.pool),
      Provider<EngineSearchBudget>.value(value: _engines.budget),
      ChangeNotifierProvider<EngineLifecycle>.value(value: _engines.lifecycle),
      Provider<GenerationLease>.value(value: _engines.lease),
      ChangeNotifierProvider<EngineSettings>.value(value: _runtime.engine),
      ChangeNotifierProvider<BulkAnalysisSettings>.value(value: _runtime.bulk),
      ChangeNotifierProvider<BoardDisplaySettings>.value(
        value: _runtime.display,
      ),
    ],
    child: widget.child,
  );
}

/// Adopt only on the verified host; the remaining native commit protocols
/// keep their documented legacy adapter until their platform gates pass.
PgnDocumentStore createPlatformDocumentStore() {
  final storage = StorageFactory.instance;
  if (!Platform.isLinux) return LegacyPgnDocumentStore(storage);
  return NativePgnDocumentStore(
    guardOperation: storage is IOStorageService
        ? storage.guardDocumentOperation
        : null,
  );
}

PgnCollectionRepository createPgnCollectionRepository({
  required PgnDocumentStore documents,
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
