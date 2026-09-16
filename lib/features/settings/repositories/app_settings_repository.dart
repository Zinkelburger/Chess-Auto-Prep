import '../models/repertoire_books.dart';
import '../models/settings_state.dart';

/// One entry point for settings ownership. Sections migrate here when their
/// workflows migrate; engine/display/training sections still use legacy owners.
abstract interface class AppSettingsRepository {
  RepertoireBooksRepository get repertoireBooks;
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
