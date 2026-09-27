enum SettingsPhase { unloaded, loading, ready, saving, failed }

/// A draft never replaces [committed] until persistence confirms it.
class SettingsState<T> {
  const SettingsState({
    this.phase = SettingsPhase.unloaded,
    this.committed,
    this.draft,
    this.error,
  });

  final SettingsPhase phase;
  final T? committed;
  final T? draft;
  final Object? error;
  bool get busy =>
      phase == SettingsPhase.loading || phase == SettingsPhase.saving;
}
