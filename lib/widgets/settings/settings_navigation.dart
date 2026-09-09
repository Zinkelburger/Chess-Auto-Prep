import 'package:flutter/material.dart';

import '../../core/app_state.dart';

/// View-owned builders are registered by mounted gears. Lazy views can mount
/// underneath the settings route without replacing that route.
class ViewSettingsRegistry extends ChangeNotifier {
  static final _registries = Expando<ViewSettingsRegistry>();
  static ViewSettingsRegistry forApp(AppState app) =>
      _registries[app] ??= ViewSettingsRegistry();

  final Map<
    AppMode,
    ({Object owner, WidgetBuilder? builder, VoidCallback? onClosed})
  >
  entries = {};

  void register(
    AppMode mode,
    Object owner,
    WidgetBuilder? builder,
    VoidCallback? onClosed,
  ) {
    entries[mode] = (owner: owner, builder: builder, onClosed: onClosed);
    notifyListeners();
  }

  void unregister(AppMode mode, Object owner) {
    if (entries[mode]?.owner == owner) {
      entries.remove(mode);
      // Disposal can happen during a build; listeners refresh next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
    }
  }
}

class SettingsChapter {
  const SettingsChapter(this.label);
  final String label;
}

List<SettingsChapter> settingsChapters(AppMode mode) => switch (mode) {
  AppMode.repertoireTrainer => const [
    SettingsChapter('Session'),
    SettingsChapter('Learning'),
    SettingsChapter('Playback'),
    SettingsChapter('Material'),
  ],
  AppMode.tactics => const [
    SettingsChapter('Session'),
    SettingsChapter('Puzzle selection'),
    SettingsChapter('Game downloads'),
    SettingsChapter('Review performance'),
  ],
  AppMode.pgnViewer => const [
    SettingsChapter('Playback'),
    SettingsChapter('Board and moves'),
  ],
  AppMode.repertoire => const [
    SettingsChapter('Repertoire'),
    SettingsChapter('Analysis panels'),
    SettingsChapter('Engine analysis'),
  ],
  AppMode.databases => const [SettingsChapter('Data')],
  AppMode.bughouse => const [SettingsChapter('Engine')],
  AppMode.engineTournament => const [SettingsChapter('Engines')],
  _ => const [
    SettingsChapter('Analysis panels'),
    SettingsChapter('Engine analysis'),
    SettingsChapter('Display'),
  ],
};

/// The shared shell owns chapter selection; feature widgets own live controls.
class SettingsChapterScope extends InheritedWidget {
  const SettingsChapterScope({
    super.key,
    required this.index,
    required super.child,
  });
  final int index;
  static int? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsChapterScope>()?.index;
  @override
  bool updateShouldNotify(SettingsChapterScope oldWidget) =>
      index != oldWidget.index;
}
