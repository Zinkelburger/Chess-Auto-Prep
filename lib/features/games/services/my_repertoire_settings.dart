import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../utils/safe_change_notifier.dart';

/// Which repertoire folders are *mine* — the designated White and Black books
/// the Games page checks every game against. Nothing else in the app records
/// this: repertoire files carry a per-file `// Color:` header, but no file
/// says "this one is the repertoire I actually play".
///
/// Stored as repertoire *folder* paths (a repertoire is a directory of
/// chapter `.pgn` files); all chapters of all designated folders form that
/// color's book.
class MyRepertoireSettings extends ChangeNotifier with SafeChangeNotifier {
  MyRepertoireSettings._();

  static final MyRepertoireSettings instance = MyRepertoireSettings._();

  /// Test-only: a fresh, non-singleton instance.
  @visibleForTesting
  MyRepertoireSettings.forTest();

  static const _whiteKey = 'my_repertoire_white_paths';
  static const _blackKey = 'my_repertoire_black_paths';

  List<String> _whitePaths = const [];
  List<String> _blackPaths = const [];
  bool _loaded = false;
  Future<void>? _loading;

  List<String> get whitePaths => List.unmodifiable(_whitePaths);
  List<String> get blackPaths => List.unmodifiable(_blackPaths);
  bool get isLoaded => _loaded;
  bool get hasAny => _whitePaths.isNotEmpty || _blackPaths.isNotEmpty;

  /// The designated folders for the side [white], read-only.
  List<String> pathsFor({required bool white}) =>
      white ? whitePaths : blackPaths;

  /// Load once. Concurrent callers share the in-flight read rather than
  /// racing two prefs reads and notifying twice.
  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _whitePaths = prefs.getStringList(_whiteKey) ?? const [];
    _blackPaths = prefs.getStringList(_blackKey) ?? const [];
    _loaded = true;
    _loading = null;
    notifyListeners();
  }

  Future<void> setPaths({
    required bool white,
    required List<String> paths,
  }) async {
    if (white) {
      _whitePaths = List.of(paths);
    } else {
      _blackPaths = List.of(paths);
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(white ? _whiteKey : _blackKey, paths);
  }

  Future<void> addPath({required bool white, required String path}) async {
    final current = pathsFor(white: white);
    if (current.contains(path)) return;
    await setPaths(white: white, paths: [...current, path]);
  }

  Future<void> removePath({required bool white, required String path}) async {
    final current = pathsFor(white: white);
    if (!current.contains(path)) return;
    await setPaths(
      white: white,
      paths: [
        for (final p in current)
          if (p != path) p,
      ],
    );
  }
}
