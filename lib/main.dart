import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/app_state.dart';
import 'screens/main_screen.dart';
import 'services/tactics_service.dart';
import 'services/pgn_service.dart';
import 'services/imported_games_service.dart';
import 'services/browser_extension_server/browser_extension_server_factory.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Start the browser extension server on desktop platforms
  // This allows the Lichess browser extension to add lines to repertoires
  _startBrowserExtensionServer();
  
  runApp(const ChessAutoPrepApp());
}

/// Start the browser extension HTTP server on supported platforms (desktop only)
/// The server listens on localhost:9812 and handles requests from the Lichess extension
void _startBrowserExtensionServer() async {
  if (BrowserExtensionServerFactory.isSupported) {
    final started = await BrowserExtensionServerFactory.start(port: 9812);
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
        Provider(create: (_) => TacticsService()),
        Provider(create: (_) => PgnService()),
        Provider(create: (_) => ImportedGamesService()),
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
            surface: Color(0xFF121212),
            onSurface: Colors.white,
            primary: Color(0xFF404040),
            onPrimary: Colors.white,
            secondary: Color(0xFF606060),
            onSecondary: Colors.white,
          ),
          scaffoldBackgroundColor: const Color(0xFF121212),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF1E1E1E),
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
          snackBarTheme: SnackBarThemeData(
            backgroundColor: Colors.grey[900],
            contentTextStyle: const TextStyle(color: Colors.white),
            behavior: SnackBarBehavior.floating,
          ),
          useMaterial3: true,
        ),
        home: const MainScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}