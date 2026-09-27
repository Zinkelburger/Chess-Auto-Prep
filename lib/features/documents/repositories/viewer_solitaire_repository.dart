typedef ViewerSolitaireSettings = ({
  int revealDelaySeconds,
  bool includeVariations,
  int trophyCount,
});

abstract interface class ViewerSolitaireRepository {
  Future<ViewerSolitaireSettings> load();
  Future<void> saveRevealDelay(int seconds);
  Future<void> saveIncludeVariations(bool value);
}
