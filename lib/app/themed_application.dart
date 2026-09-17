import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../design_system/theme/app_theme.dart';
import '../features/settings/controllers/settings_providers.dart';
import '../features/settings/models/app_appearance.dart';
import '../l10n/generated/app_localizations.dart';

/// Appearance is an app-owned preference; feature widgets read the resolved
/// Theme, including platform brightness, rather than platform callbacks.
class ThemedApplication extends ConsumerWidget {
  const ThemedApplication({super.key, required this.home, this.builder});
  final Widget home;
  final TransitionBuilder? builder;
  static final _light = AppTheme.light();
  static final _dark = AppTheme.dark();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(
      appearanceSettingsProvider.select(
        (state) => state.asData?.value.committed ?? AppAppearance.dark,
      ),
    );
    return MaterialApp(
      title: 'Chess Auto Prep',
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: _light,
      darkTheme: _dark,
      themeMode: switch (appearance) {
        AppAppearance.dark => ThemeMode.dark,
        AppAppearance.light => ThemeMode.light,
        AppAppearance.system => ThemeMode.system,
      },
      builder: builder,
      home: home,
      debugShowCheckedModeBanner: false,
    );
  }
}
