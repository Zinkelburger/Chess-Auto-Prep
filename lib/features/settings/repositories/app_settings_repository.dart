import '../models/repertoire_books.dart';
import '../models/app_appearance.dart';
import '../models/settings_state.dart';

/// One entry point for settings ownership. Sections migrate here when their
/// workflows migrate; engine/board-display/training sections still use legacy owners.
abstract interface class AppSettingsRepository {
  RepertoireBooksRepository get repertoireBooks;
  AppearanceRepository get appearance;
}

abstract interface class RepertoireBooksRepository {
  SettingsState<RepertoireBooks> get state;
  Stream<SettingsState<RepertoireBooks>> get changes;
  Future<void> ensureLoaded();
  Future<void> reload();
  Future<void> setPaths(BookSide side, List<String> paths);
  Future<void> addPath(BookSide side, String path);
  Future<void> removePath(BookSide side, String path);
  Future<void> relocate({required String from, required String to});

  /// Explicitly reapply the failed operation against the latest saved values.
  Future<void> retry();
}

abstract interface class AppearanceRepository {
  SettingsState<AppAppearance> get state;
  Stream<SettingsState<AppAppearance>> get changes;
  Future<void> ensureLoaded();
  Future<void> reload();
  Future<void> setAppearance(AppAppearance value);
  Future<void> retry();
}
