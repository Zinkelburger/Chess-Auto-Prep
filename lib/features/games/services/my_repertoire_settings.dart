import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../infrastructure/settings/shared_preferences_app_settings_repository.dart';
import '../../../utils/safe_change_notifier.dart';
import '../../settings/models/repertoire_books.dart';
import '../../settings/models/settings_state.dart';
import '../../settings/repositories/app_settings_repository.dart';

/// Temporary ChangeNotifier adapter for Games callers. It owns no preference
/// keys or committed state; both new and old callers use the same repository.
class MyRepertoireSettings extends ChangeNotifier with SafeChangeNotifier {
  MyRepertoireSettings({required this.repository}) {
    var last = repository.state.committed;
    _subscription = repository.changes.listen((state) {
      if (state.committed != last) {
        last = state.committed;
        notifyListeners();
      }
    });
  }

  static final MyRepertoireSettings instance = MyRepertoireSettings(
    repository: SharedPreferencesAppSettingsRepository.instance.repertoireBooks,
  );

  @visibleForTesting
  MyRepertoireSettings.forTest()
    : this(
        repository: SharedPreferencesAppSettingsRepository().repertoireBooks,
      );

  final RepertoireBooksRepository repository;
  late final StreamSubscription<SettingsState<RepertoireBooks>> _subscription;

  SettingsState<RepertoireBooks> get state => repository.state;
  List<String> get whitePaths => state.committed?.white ?? const [];
  List<String> get blackPaths => state.committed?.black ?? const [];
  bool get isLoaded => state.committed != null;
  bool get hasAny => state.committed?.hasAny ?? false;
  List<String> pathsFor({required bool white}) =>
      white ? whitePaths : blackPaths;

  Future<void> ensureLoaded() => repository.ensureLoaded();
  Future<void> retry() => repository.retry();
  Future<void> setPaths({required bool white, required List<String> paths}) =>
      repository.setPaths(white ? BookSide.white : BookSide.black, paths);
  Future<void> addPath({required bool white, required String path}) =>
      repository.addPath(white ? BookSide.white : BookSide.black, path);
  Future<void> removePath({required bool white, required String path}) =>
      repository.removePath(white ? BookSide.white : BookSide.black, path);

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
