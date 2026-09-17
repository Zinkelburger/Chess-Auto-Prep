import 'package:chess_auto_prep/debug/agent_driver.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import 'repertoire_cases.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  installAgentDriver();
  runApp(const RenewalWidgetbook());
}

/// Local development catalog. No account, settings, engine or disk owner is
/// constructed; use cases supply memory repositories and picker/navigation fakes.
class RenewalWidgetbook extends StatelessWidget {
  const RenewalWidgetbook({
    super.key,
    this.initialRoute = '/?path=repertoires/library/populated',
  });
  final String initialRoute;

  @override
  Widget build(BuildContext context) => Widgetbook.material(
    initialRoute: initialRoute,
    lightTheme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: ThemeMode.dark,
    addons: [
      MaterialThemeAddon(
        themes: [
          WidgetbookTheme(name: 'Dark', data: AppTheme.dark()),
          WidgetbookTheme(name: 'Light', data: AppTheme.light()),
        ],
      ),
      TextScaleAddon(min: 1, max: 2, divisions: 2, initialScale: 1),
    ],
    directories: repertoireCases(),
  );
}
