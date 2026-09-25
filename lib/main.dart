import 'features/repertoires/repositories/repertoire_catalog_repository.dart';
import 'features/repertoire/services/repertoire_outline_service.dart';
import 'app/builder_lifetime.dart';
import 'features/studies/repositories/study_import_repository.dart';
import 'features/studies/widgets/study_save_button.dart'
    show chooseStudyCopyDestination;
import 'features/studies/widgets/study_import_close_guard.dart';
import 'features/studies/controllers/study_import_controller.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'app/engine_runtime.dart';
import 'app/runtime_settings.dart';
import 'features/generation/services/generation_artifacts.dart';
import 'app/generation_dependencies.dart';
import 'features/generation/controllers/generation_publication_controller.dart';
import 'app/viewer_dependencies.dart';
import 'app/repertoire_dependencies.dart';
import 'features/repertoires/repositories/repertoire_document_repository.dart';
import 'features/repertoires/repositories/repertoire_decoder.dart';
import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:chess_auto_prep/features/studies/models/study_workspace_snapshot.dart';
import 'app/pgn_viewer_lifetime.dart';
import 'features/documents/models/pgn_workspace_snapshot.dart';
import 'features/documents/repositories/pgn_collection_repository.dart';
import 'l10n/generated/app_localizations.dart';
import 'infrastructure/settings/fresh_desktop_preferences_store.dart';
import 'infrastructure/settings/shared_preferences_app_settings_repository.dart';

import 'app/app_dependencies.dart';
import 'app/document_dependencies.dart';
import 'app/study_dependencies.dart';
import 'app/desktop_application.dart';
import 'features/documents/repositories/desktop_close_port.dart';
import 'features/settings/repositories/app_settings_repository.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'features/updates/widgets/app_updates.dart';
import 'core/app_history.dart';
import 'core/app_state.dart';
import 'features/studies/controllers/study_controller.dart';
import 'features/studies/widgets/study_close_guard.dart';
import 'features/documents/widgets/workspace_recovery_host.dart';
import 'features/documents/controllers/workspace_recovery_controller.dart';
import 'features/documents/repositories/workspace_recovery_store.dart';
import 'features/bughouse/services/bughouse_bundle.dart';
import 'debug/agent_driver.dart';
import 'features/settings/controllers/bulk_analysis_settings.dart';
import 'screens/main_screen.dart';
import 'theme/app_colors.dart';
import 'design_system/theme/app_theme.dart';

import 'services/default_pgn_service.dart';
import 'services/engine/engine_lifecycle.dart';
import 'services/eval_cache.dart';
import 'services/master_games/master_games_service.dart';
import 'services/bundled_licenses.dart';
import 'infrastructure/diagnostics/app_log_file.dart';
import 'utils/log.dart';
import 'widgets/escape_to_pop_scope.dart';

void main() {
  unawaited(
    runZonedGuarded(
      () async {
        WidgetsFlutterBinding.ensureInitialized();
        // Before anything that can fail: a startup failure is exactly the
        // one a user cannot read off the screen.
        await AppLogFile.install();
        installFreshDesktopPreferencesStore();
        registerBundledLicenses();
        // No-op unless --dart-define=AGENT_DRIVER=true in a debug build.
        installAgentDriver();

        FlutterError.onError = (FlutterErrorDetails details) {
          FlutterError.presentError(details);
          log.e(
            'Flutter error while ${details.context ?? 'running'}',
            name: 'Flutter',
            error: details.exception,
            stackTrace: details.stack,
          );
        };

        try {
          final runtime = RuntimeSettings.preferences();
          final engines = EngineRuntime(settings: runtime.engine);
          await _initializeApp(runtime, engines);
          runApp(
            ChessAutoPrepApp(runtimeSettings: runtime, engineRuntime: engines),
          );
        } catch (error, stackTrace) {
          log.e(
            'Startup failed',
            name: 'Startup',
            error: error,
            stackTrace: stackTrace,
          );
          runApp(StartupErrorApp(error: error, stackTrace: stackTrace));
        }
      },
      (error, stackTrace) {
        log.e('Uncaught async error', error: error, stackTrace: stackTrace);
      },
    ),
  );
}

Future<void> _initializeApp(
  RuntimeSettings runtime,
  EngineRuntime engines,
) async {
  // Required before runApp (configures the native window).
  await windowManager.ensureInitialized();

  // Load independent settings concurrently before runApp so the first
  // render reflects the user's saved engine/eval preferences.
  //
  // The bughouse probe joins them for the same reason: the mode menu is built
  // in the first frame, and a mode that appears and then vanishes is worse
  // than one that was never offered. It reads the asset manifest, so it costs
  // a manifest parse rather than a disk round-trip.
  await Future.wait([
    // Start in the saved appearance without flashing the default. A settings
    // read failure stays recoverable from Appearance rather than blocking boot.
    SharedPreferencesAppSettingsRepository.instance.appearance
        .ensureLoaded()
        .catchError((Object _) {}),
    runtime.load(),
    engines.lifecycle.loadPersistedState().catchError((Object _) {}),
    _resolveOptionalModes(),
  ]);

  // The persistent eval cache opens a SQLite database — nothing on the first
  // screen (Tactics) needs it. Warm it in the background; get/put await the
  // same idempotent init() future so early engine-pane writes wait for the
  // DB instead of sticking in the L1 memory map only.
  unawaited(EvalCache.instance.init());
  // Master-games coverage for the settings panel and the generator.
  unawaited(
    MasterGamesService.instance.load().then(
      (_) => MasterGamesService.instance.autoSyncIfDue(),
    ),
  );

  unawaited(DefaultPgnService.ensureExtracted());
}

/// Decides which optional modes this build can actually run, so the mode menu
/// only ever offers something that works.
///
/// Bughouse ships an engine that is downloaded into `assets/bughouse/` at
/// release time rather than tracked in git, and Flutter does not fail a build
/// whose declared asset directory is missing — so "no engine in this build" is
/// an ordinary state, and every developer checkout is in it until
/// `tools/fetch_assets.py` has run.
Future<void> _resolveOptionalModes() async {
  if (!await BughouseBundle.probeBundled()) {
    unavailableModes.add(AppMode.bughouse);
  }
}

/// Shown when startup initialization fails before [ChessAutoPrepApp] can run.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error, this.stackTrace});

  final Object error;
  final StackTrace? stackTrace;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.dark(),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: AppColors.danger,
                  size: 48,
                ),
                const SizedBox(height: 16),
                Text(
                  'Chess Auto Prep failed to start',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text('$error'),
                if (stackTrace != null) ...[
                  const SizedBox(height: 16),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Text(
                        '$stackTrace',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ChessAutoPrepApp extends StatelessWidget {
  const ChessAutoPrepApp({
    super.key,
    this.settings,
    this.runtimeSettings,
    this.engineRuntime,
    this.closePort,
    this.studyRecoveryStore,
    this.pgnRecoveryStore,
    this.repertoireDocuments,
  });
  final RepertoireDocumentRepository? repertoireDocuments;
  final AppSettingsRepository? settings;
  final RuntimeSettings? runtimeSettings;
  final EngineRuntime? engineRuntime;
  final DesktopClosePort? closePort;
  final WorkspaceRecoveryStore<StudyWorkspaceSnapshot>? studyRecoveryStore;
  final WorkspaceRecoveryStore<PgnWorkspaceSnapshot>? pgnRecoveryStore;

  @override
  Widget build(BuildContext context) {
    final documents = createPlatformDocumentStore();
    return AppDependencies(
      settings: settings,
      runtimeSettings: runtimeSettings,
      engineRuntime: engineRuntime,
      documentStore: documents,
      child: MultiProvider(
        providers: [
          Provider<GenerationArtifacts>(
            create: (_) => createGenerationArtifacts(documents: documents),
          ),
          Provider<GenerationPublicationFactory>(
            create: (_) =>
                () => createGenerationPublication(documents: documents),
          ),
          Provider<RepertoireDocumentRepository>(
            create: (_) =>
                repertoireDocuments ??
                createRepertoireDocuments(documents: documents),
          ),
          Provider<RepertoireOutlineService>(
            create: (context) => createRepertoireOutline(
              documents: documents,
              catalog: context.read<RepertoireCatalogRepository>(),
            ),
          ),
          Provider<RepertoireDecoder>(create: (_) => createRepertoireDecoder()),
          Provider<BuilderLifetime>(
            create: (ctx) => BuilderLifetime(
              documents: ctx.read<RepertoireDocumentRepository>(),
              decoder: ctx.read<RepertoireDecoder>(),
              store: createBuilderRecoveryStore(),
            ),
            dispose: (_, lifetime) => lifetime.dispose(),
          ),
          Provider<PgnCollectionRepository>(
            create: (_) => createPgnCollectionRepository(documents: documents),
          ),
          Provider<PgnViewerLifetime>(
            create: (ctx) => PgnViewerLifetime(
              pool: ctx.read<StockfishPool>(),
              lifecycle: ctx.read<EngineLifecycle>(),
              bulkDepth: () => ctx.read<BulkAnalysisSettings>().depth,
              positionIndex: createViewerPositionIndex(),
              openings: createViewerOpenings(),
              solitaireRepository: createViewerSolitaire(),
              window: createViewerWindowPort(),
              preferences: createViewerPreferencesRepository(),
              collectionDecoder: createPgnCollectionDecoder(),
              collectionFilter: createPgnCollectionFilter(),
              library: createPgnLibraryRepository(),
              repository: ctx.read<PgnCollectionRepository>(),
              store: pgnRecoveryStore ?? createPgnRecoveryStore(),
            ),
            dispose: (_, lifetime) => lifetime.dispose(),
          ),
          ChangeNotifierProvider(
            create: (_) {
              final appState = AppState();
              unawaited(appState.loadUsernames());
              return appState;
            },
          ),
          // Not lazy: the history must exist from the first frame or early
          // handoffs would go unrecorded and the trail would lie.
          ChangeNotifierProvider<AppHistory>(
            lazy: false,
            create: (ctx) => AppHistory(ctx.read<AppState>()),
          ),
          // App-scoped singletons exposed through Provider so widgets/tests can
          // depend on them via context (instead of global `.instance` access) and
          // inject fakes in tests. `.value` because these are process singletons
          // (`.instance`) that must not be disposed by the provider.
          ChangeNotifierProvider<MasterGamesService>.value(
            value: MasterGamesService.instance,
          ),
          // App-scoped (not study-mode-scoped) so other modes can add chapters
          // ("Add line to study" in the PGN viewer) through the same document
          // the study screen edits.
          ChangeNotifierProvider<StudyController>(
            create: (_) => createStudyController(documents: documents),
          ),
          Provider<StudyImportRepository>(
            create: (_) => createStudyImportRepository(documents: documents),
          ),
          ChangeNotifierProvider<StudyImportController>(
            create: (context) => createStudyImportController(
              documents: documents,
              repository: context.read<StudyImportRepository>(),
            ),
          ),
          ChangeNotifierProvider<
            WorkspaceRecoveryController<StudyWorkspaceSnapshot>
          >(
            create: (ctx) =>
                WorkspaceRecoveryController<StudyWorkspaceSnapshot>(
                  workspace: ctx.read<StudyController>(),
                  capture: ctx.read<StudyController>().captureWorkspace,
                  restoreSnapshot: ctx.read<StudyController>().restoreWorkspace,
                  store: studyRecoveryStore ?? createStudyRecoveryStore(),
                ),
          ),
        ],
        // Boards and move lists read the Display preferences through this scope
        // so a change in Settings repaints them in place.
        child: DesktopApplication(
          closePort: closePort,
          // Keep the semantics tree empty unless explicitly enabled —
          // GNOME's accessibility bus can enable Flutter's semantics tree
          // and then assert every frame on our recognizer-per-span movetext
          // (flutter/flutter#169214). Pass --dart-define=ENABLE_SEMANTICS=true
          // to re-enable when testing a Flutter pin that includes the fix.
          builder: (context, child) {
            final wrapped = EscapeToPopScope(child: child!);
            const enableSemantics = bool.fromEnvironment('ENABLE_SEMANTICS');
            if (enableSemantics) return wrapped;
            return ExcludeSemantics(child: wrapped);
          },
          home: Builder(
            builder: (context) => AppUpdateHost(
              child: StudyImportCloseGuard(
                importer: context.read<StudyImportController>(),
                chooseCopyDestination: (context) => chooseStudyCopyDestination(
                  context,
                  context.read<StudyController>(),
                ),
                child: StudyCloseGuard(
                  study: context.read<StudyController>(),
                  child: WorkspaceRecoveryHost<StudyWorkspaceSnapshot>(
                    id: 'study',
                    workspaceName: AppLocalizations.of(
                      context,
                    ).studyWorkspaceName,
                    title: (snapshot) => snapshot.name,
                    path: (snapshot) => snapshot.path,
                    recovery: context
                        .read<
                          WorkspaceRecoveryController<StudyWorkspaceSnapshot>
                        >(),
                    onRestored: () =>
                        context.read<AppState>().setMode(AppMode.study),
                    child: WorkspaceRecoveryHost<PgnWorkspaceSnapshot>(
                      id: 'pgn',
                      workspaceName: AppLocalizations.of(
                        context,
                      ).pgnWorkspaceName,
                      title: (snapshot) => snapshot.path.isEmpty
                          ? AppLocalizations.of(context).untitledPgnWorkspace
                          : p.basename(snapshot.path),
                      path: (snapshot) => snapshot.path,
                      recovery: context.read<PgnViewerLifetime>().recovery,
                      onRestored: () =>
                          context.read<AppState>().setMode(AppMode.pgnViewer),
                      child: PgnViewerCloseHost(
                        lifetime: context.read<PgnViewerLifetime>(),
                        child: BuilderWorkspaceHost(
                          lifetime: context.read<BuilderLifetime>(),
                          onRestored: () => context.read<AppState>().setMode(
                            AppMode.repertoire,
                          ),
                          child: const MainScreen(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
