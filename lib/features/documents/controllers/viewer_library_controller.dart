import 'package:flutter/foundation.dart';
import '../../../utils/safe_change_notifier.dart';
import '../repositories/pgn_library_repository.dart';
import '../repositories/viewer_preferences_repository.dart';

/// Library discovery and recent-file preferences, independent of a document.
class ViewerLibraryController extends ChangeNotifier with SafeChangeNotifier {
  ViewerLibraryController({
    required this.library,
    required this.preferences,
    required this.isActive,
  });
  final PgnLibraryRepository library;
  final ViewerPreferencesRepository preferences;
  final bool Function() isActive;
  List<String> _recentFiles = const [];
  List<String> get recentFiles => _recentFiles;
  String? _collectionsDir;
  String? get collectionsDir => _collectionsDir;
  String? _recentError;
  String? _collectionsError;
  String? get errorMessage => _recentError ?? _collectionsError;
  Future<void> _pendingWrites = Future.value();
  static const maxRecentFiles = 10;
  int _recentEpoch = 0;
  Future<void> loadRecentFiles() async {
    final epoch = ++_recentEpoch;
    try {
      final files = await preferences.loadRecentFiles();
      final existing = <String>[];
      for (final f in files) {
        if (await library.exists(f)) existing.add(f);
      }
      if (isDisposed || !isActive() || epoch != _recentEpoch) return;
      _recentFiles = List.unmodifiable(existing);
      _recentError = null;
      notifyListeners();
    } catch (_) {
      if (isDisposed || !isActive() || epoch != _recentEpoch) return;
      _recentError = 'Could not load recent PGN files.';
      notifyListeners();
    }
  }

  Future<void> loadCollections() async {
    try {
      final dir = await library.collectionsDirectory();
      if (isDisposed || !isActive()) return;
      _collectionsDir = dir;
      _collectionsError = null;
      notifyListeners();
    } catch (_) {
      if (isDisposed || !isActive()) return;
      _collectionsError = 'Could not locate the PGN library.';
      notifyListeners();
    }
  }

  Future<void> addToRecentFiles(String path) async {
    if (isDisposed || !isActive()) return;
    final epoch = ++_recentEpoch;
    _recentFiles = List.unmodifiable(
      [
        path,
        ..._recentFiles.where((existing) => existing != path),
      ].take(maxRecentFiles),
    );
    final captured = _recentFiles;
    final write = _pendingWrites.then(
      (_) => preferences.saveRecentFiles(captured),
    );
    _pendingWrites = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    notifyListeners();
    try {
      await write;
      if (isDisposed || !isActive() || epoch != _recentEpoch) return;
      _recentError = null;
    } catch (_) {
      if (isDisposed || !isActive() || epoch != _recentEpoch) return;
      _recentError = 'Could not save recent PGN files.';
    }
    notifyListeners();
  }

  String? pickFileInitialDirectory(String? currentPath) {
    if (currentPath != null) {
      return library.parentDirectory(currentPath);
    }
    if (recentFiles.isNotEmpty) {
      return library.parentDirectory(recentFiles.first);
    }
    return collectionsDir;
  }
}
