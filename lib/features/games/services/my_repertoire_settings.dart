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

  List<String> get whitePaths => List.unmodifiable(_whitePaths);
  List<String> get blackPaths => List.unmodifiable(_blackPaths);
  bool get isLoaded => _loaded;
  bool get hasAny => _whitePaths.isNotEmpty || _blackPaths.isNotEmpty;

  List<String> pathsFor({required bool white}) =>
      white ? whitePaths : blackPaths;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _whitePaths = prefs.getStringList(_whiteKey) ?? const [];
    _blackPaths = prefs.getStringList(_blackKey) ?? const [];
    _loaded = true;
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
    final current = white ? _whitePaths : _blackPaths;
    if (current.contains(path)) return;
    await setPaths(white: white, paths: [...current, path]);
  }

  Future<void> removePath({required bool white, required String path}) async {
    final current = white ? _whitePaths : _blackPaths;
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
