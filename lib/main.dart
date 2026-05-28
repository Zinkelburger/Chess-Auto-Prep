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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  await EngineSettings().loadFromPrefs();
  await EvalDatabaseSettings.instance.load();
  await EngineLifecycle().loadPersistedState();

  _startBrowserExtensionServer();
  DefaultPgnService.ensureExtracted();

  runApp(const ChessAutoPrepApp());
}

void _startBrowserExtensionServer() async {
  if (BrowserExtensionServerFactory.isSupported) {
    final started = await BrowserExtensionServerFactory.start(
        port: kBrowserExtensionPort);
    if (started) {
      debugPrint('Browser extension server started successfully');
    } else {
      debugPrint('Failed to start browser extension server');
    }
  } else {
    debugPrint('Browser extension server not supported on this platform');
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
            appState.loadUsernames(); // Load saved usernames
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
