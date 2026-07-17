import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'constants/engine_defaults.dart';
import 'core/app_state.dart';
import 'core/study_controller.dart';
import 'models/engine_settings.dart';
import 'models/eval_database_settings.dart';
import 'screens/main_screen.dart';
import 'theme/app_colors.dart';
import 'theme/app_text_styles.dart';

import 'services/browser_extension_server/browser_extension_server_factory.dart';
import 'services/default_pgn_service.dart';
import 'services/engine/engine_lifecycle.dart';
import 'services/eval_cache.dart';

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        debugPrint('FlutterError: ${details.exceptionAsString()}');
      };

      try {
        await _initializeApp();
        runApp(const ChessAutoPrepApp());
      } catch (error, stackTrace) {
        debugPrint('Startup failed: $error\n$stackTrace');
        runApp(StartupErrorApp(error: error, stackTrace: stackTrace));
      }
    },
    (error, stackTrace) {
      debugPrint('Uncaught async error: $error\n$stackTrace');
    },
  );
}

Future<void> _initializeApp() async {
  // Required before runApp (configures the native window).
  await windowManager.ensureInitialized();

  // These three are independent SharedPreferences/settings loads — run them
  // concurrently instead of serially so the first frame isn't gated on three
  // sequential disk round-trips. They must finish before runApp so the first
  // render reflects the user's saved engine/eval preferences.
  await Future.wait([
    EngineSettings.instance.loadFromPrefs(),
    EvalDatabaseSettings.instance.load(),
    EngineLifecycle.instance.loadPersistedState(),
  ]);

  // The persistent eval cache opens a SQLite database — nothing on the first
  // screen (Tactics) needs it. Warm it in the background; get/put await the
  // same idempotent init() future so early engine-pane writes wait for the
  // DB instead of sticking in the L1 memory map only.
  unawaited(EvalCache.instance.init());

  _startBrowserExtensionServer();
  DefaultPgnService.ensureExtracted();
}

void _startBrowserExtensionServer() async {
  if (BrowserExtensionServerFactory.isSupported) {
    final started = await BrowserExtensionServerFactory.start(
      port: kBrowserExtensionPort,
    );
    if (started) {
      debugPrint('Browser extension server started successfully');
    } else {
      debugPrint('Failed to start browser extension server');
    }
  } else {
    debugPrint('Browser extension server not supported on this platform');
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
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          surface: AppColors.surface,
          onSurface: AppColors.ink,
          error: AppColors.danger,
        ),
        scaffoldBackgroundColor: AppColors.surface,
        useMaterial3: true,
      ),
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
  const ChessAutoPrepApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) {
            final appState = AppState();
            appState.loadUsernames();
            return appState;
          },
        ),
        // App-scoped singletons exposed through Provider so widgets/tests can
        // depend on them via context (instead of global `.instance` access) and
        // inject fakes in tests. `.value` because these are process singletons
        // (`.instance`) that must not be disposed by the provider.
        ChangeNotifierProvider<EngineSettings>.value(
          value: EngineSettings.instance,
        ),
        ChangeNotifierProvider<EvalDatabaseSettings>.value(
          value: EvalDatabaseSettings.instance,
        ),
        ChangeNotifierProvider<EngineLifecycle>.value(
          value: EngineLifecycle.instance,
        ),
        // App-scoped (not study-mode-scoped) so other modes can add chapters
        // ("Add line to study" in the PGN viewer) through the same document
        // the study screen edits.
        ChangeNotifierProvider<StudyController>(
          create: (_) => StudyController(),
        ),
      ],
      child: MaterialApp(
        title: 'Chess Auto Prep',
        theme: ThemeData(
          colorScheme: const ColorScheme.dark(
            surface: AppColors.surface,
            onSurface: AppColors.ink,
            primary: AppColors.ink,
            onPrimary: AppColors.surface,
            primaryContainer: AppColors.surfaceContainer,
            onPrimaryContainer: AppColors.ink,
            secondary: AppColors.surfaceHighlight,
            onSecondary: AppColors.ink,
            tertiary: AppColors.expectimax,
            onTertiary: AppColors.surface,
            error: AppColors.danger,
            onError: AppColors.ink,
          ),
          scaffoldBackgroundColor: AppColors.surface,
          dividerColor: AppColors.divider,
          textTheme: AppTextStyles.materialTextTheme(),
          appBarTheme: const AppBarTheme(
            backgroundColor: AppColors.surfaceElevated,
            foregroundColor: AppColors.ink,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              foregroundColor: AppColors.ink,
              backgroundColor: AppColors.buttonSurface,
            ),
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(foregroundColor: AppColors.ink),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(foregroundColor: AppColors.ink),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              foregroundColor: AppColors.ink,
              backgroundColor: AppColors.buttonSurface,
            ),
          ),
          snackBarTheme: SnackBarThemeData(
            backgroundColor: AppColors.surfaceInset,
            contentTextStyle: AppTextStyles.body.copyWith(fontSize: 15),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          useMaterial3: true,
        ),
        home: const MainScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
