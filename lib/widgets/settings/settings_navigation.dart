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
  const SettingsChapter(this.label, this.description);
  final String label;
  final String description;
}

List<SettingsChapter> settingsChapters(AppMode mode) => switch (mode) {
  AppMode.repertoireTrainer => const [
    SettingsChapter('Session', 'Choose what to practise and how much to do.'),
    SettingsChapter('Learning', 'Choose how moves are learned and reviewed.'),
    SettingsChapter('Playback', 'Set the pace and when to move on.'),
    SettingsChapter(
      'Material',
      'Choose your playing side and organise your chapters and lines.',
    ),
  ],
  AppMode.tactics => const [
    SettingsChapter(
      'Session',
      'Choose puzzle order and how your answers are checked. Changes apply to your next session.',
    ),
    SettingsChapter(
      'Puzzle selection',
      'Choose which mistakes stay in your practice queue. Your saved puzzles are kept.',
    ),
    SettingsChapter(
      'Game downloads',
      'Choose which games to fetch and when to review them. Apply saves your changes.',
    ),
    SettingsChapter(
      'Review performance',
      'Balance analysis accuracy with time and computer resources. Apply saves your changes.',
    ),
  ],
  AppMode.pgnViewer => const [
    SettingsChapter('Playback', 'Choose how games play through automatically.'),
    SettingsChapter(
      'Board and moves',
      'Choose orientation and reading options for this game view.',
    ),
  ],
  AppMode.repertoire => const [
    SettingsChapter(
      'Repertoire',
      'Choose the side to play and the board size for your repertoire.',
    ),
    SettingsChapter(
      'Analysis panels',
      'Choose which reference panels appear beside the board.',
    ),
    SettingsChapter(
      'Engine analysis',
      'Choose how Stockfish searches positions. These analysis preferences are shared across views.',
    ),
  ],
  AppMode.databases => const [
    SettingsChapter('Data', 'Manage downloads and online evaluation lookups.'),
  ],
  AppMode.bughouse => const [
    SettingsChapter(
      'Engine',
      'Configure the engine used to analyse the two boards.',
    ),
  ],
  AppMode.engineTournament => const [
    SettingsChapter(
      'Engines',
      'Manage the engines available for your tournaments.',
    ),
  ],
  _ => const [
    SettingsChapter(
      'Analysis panels',
      'Choose which reference panels appear beside the board.',
    ),
    SettingsChapter(
      'Engine analysis',
      'Choose how Stockfish searches positions. These analysis preferences are shared across views.',
    ),
    SettingsChapter(
      'Display',
      'Choose how boards and moves appear throughout the app.',
    ),
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
