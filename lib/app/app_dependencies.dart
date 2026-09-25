import 'document_dependencies.dart';
import '../features/settings/controllers/eval_database_settings.dart';
import '../services/eval/cdb_snapshot_download.dart';
import '../services/eval/lichess_eval_controller.dart';
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
import 'package:provider/provider.dart';
import 'training_dependencies.dart';
import '../features/training/controllers/training_settings_controller.dart';

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
import '../infrastructure/documents/isolate_pgn_collection_decoder.dart';
import '../infrastructure/documents/isolate_pgn_collection_filter.dart';
import '../infrastructure/documents/shared_preferences_viewer_repository.dart';
import '../infrastructure/documents/storage_pgn_collection_repository.dart';
import '../infrastructure/documents/storage_pgn_library_repository.dart';
import '../infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import '../infrastructure/settings/shared_preferences_app_settings_repository.dart';
import '../services/default_pgn_service.dart';
import '../services/game_store/game_store_service.dart';
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
  final TrainingSettingsController? trainingSettings;
  final RuntimeSettings? runtimeSettings;
  final EngineRuntime? engineRuntime;

  @override
  State<AppDependencies> createState() => _AppDependenciesState();
}

class _AppDependenciesState extends State<AppDependencies> {
  late final _runtime = widget.runtimeSettings ?? RuntimeSettings.preferences();
  late final _engines =
      widget.engineRuntime ?? EngineRuntime(settings: _runtime.engine);
  late final _cdb = CdbSnapshotDownloadController(settings: _runtime.databases);
  late final _lichess = LichessEvalController(settings: _runtime.databases);
  @override
  void initState() {
    super.initState();
    unawaited(_runtime.load());
    unawaited(_trainingSettings.ensureLoaded().catchError((Object _) {}));
    if (widget.engineRuntime == null) {
      unawaited(
        _engines.lifecycle.loadPersistedState().catchError((Object _) {}),
      );
    }
  }

  TrainingSettingsController? _ownedTrainingSettings;
  TrainingSettingsController get _trainingSettings =>
      widget.trainingSettings ??
      (_ownedTrainingSettings ??= createTrainingSettings());

  @override
  void didUpdateWidget(AppDependencies oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.trainingSettings, widget.trainingSettings)) {
      unawaited(_trainingSettings.ensureLoaded().catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    _ownedTrainingSettings?.dispose();
    _engines.dispose();
    _cdb.dispose();
    _lichess.dispose();
    // Admitted activation writes settle before their settings owner is disposed.
    unawaited(
      Future.wait([
        _cdb.close(),
        _lichess.close(),
      ]).whenComplete(_runtime.dispose),
    );
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
      ChangeNotifierProvider<TrainingSettingsController>.value(
        value: _trainingSettings,
      ),
      Provider<BoardEngine>.value(value: _engines.board),
      Provider<StockfishPool>.value(value: _engines.pool),
      Provider<EngineSearchBudget>.value(value: _engines.budget),
      ChangeNotifierProvider<EngineLifecycle>.value(value: _engines.lifecycle),
      Provider<GenerationLease>.value(value: _engines.lease),
      ChangeNotifierProvider<EvalDatabaseSettings>.value(
        value: _runtime.databases,
      ),
      ChangeNotifierProvider<CdbSnapshotDownloadController>.value(value: _cdb),
      ChangeNotifierProvider<LichessEvalController>.value(value: _lichess),
      ChangeNotifierProvider<EngineSettings>.value(value: _runtime.engine),
      ChangeNotifierProvider<BulkAnalysisSettings>.value(value: _runtime.bulk),
      ChangeNotifierProvider<BoardDisplaySettings>.value(
        value: _runtime.display,
      ),
    ],
    child: widget.child,
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
