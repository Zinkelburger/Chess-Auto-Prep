import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'constants/engine_defaults.dart';
import 'core/app_state.dart';
import 'models/engine_settings.dart';
import 'models/eval_database_settings.dart';
import 'screens/main_screen.dart';
import 'theme/app_colors.dart';

import 'services/browser_extension_server/browser_extension_server_factory.dart';
import 'services/default_pgn_service.dart';
import 'services/engine/engine_lifecycle.dart';
import 'services/eval_cache.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}');
  };

  runZonedGuarded(() async {
    try {
      await _initializeApp();
      runApp(const ChessAutoPrepApp());
    } catch (error, stackTrace) {
      debugPrint('Startup failed: $error\n$stackTrace');
      runApp(StartupErrorApp(error: error, stackTrace: stackTrace));
    }
  }, (error, stackTrace) {
    debugPrint('Uncaught async error: $error\n$stackTrace');
  });
}

Future<void> _initializeApp() async {
  await windowManager.ensureInitialized();

  await EngineSettings().loadFromPrefs();
  await EvalDatabaseSettings.instance.load();
  await EngineLifecycle().loadPersistedState();
  await EvalCache.instance.init();

  _startBrowserExtensionServer();
  DefaultPgnService.ensureExtracted();
}

void _startBrowserExtensionServer() async {
  if (BrowserExtensionServerFactory.isSupported) {
    final started =
        await BrowserExtensionServerFactory.start(port: kBrowserExtensionPort);
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
  const StartupErrorApp({
    super.key,
    required this.error,
    this.stackTrace,
  });

  final Object error;
  final StackTrace? stackTrace;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          surface: AppColors.surface,
          onSurface: Colors.white,
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
                const Icon(Icons.error_outline,
                    color: AppColors.danger, size: 48),
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
      ],
      child: MaterialApp(
        title: 'Chess Auto Prep',
        theme: ThemeData(
          colorScheme: const ColorScheme.dark(
            surface: AppColors.surface,
            onSurface: Colors.white,
            primary: Colors.white,
            onPrimary: AppColors.surface,
            primaryContainer: AppColors.surfaceContainer,
            onPrimaryContainer: Colors.white,
            secondary: Color(0xFF606060),
            onSecondary: Colors.white,
            tertiary: AppColors.expectimax,
            onTertiary: AppColors.surface,
            error: AppColors.danger,
            onError: Colors.white,
          ),
          scaffoldBackgroundColor: AppColors.surface,
          dividerColor: AppColors.divider,
          appBarTheme: const AppBarTheme(
            backgroundColor: AppColors.surfaceElevated,
            foregroundColor: Colors.white,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: const Color(0xFF404040),
            ),
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: const Color(0xFF404040),
            ),
          ),
          snackBarTheme: SnackBarThemeData(
            backgroundColor: Colors.grey[850],
            contentTextStyle: const TextStyle(
              color: Colors.white,
              fontSize: 15,
            ),
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
