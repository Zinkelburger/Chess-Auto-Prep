import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../../features/documents/models/viewer_session.dart';
import '../../features/documents/repositories/viewer_preferences_repository.dart';
import '../../models/pgn_filter_models.dart';

/// Keeps existing preference keys and payloads. The injected factory permits
/// storage-failure tests and avoids hidden dependencies in the session owner.
/// Ordering is app-instance local; this is not a multi-process transaction.
class SharedPreferencesViewerRepository implements ViewerPreferencesRepository {
  SharedPreferencesViewerRepository(this.preferences);
  final Future<SharedPreferences> Function() preferences;
  static const lastFileKey = 'pgn_viewer.last_file';
  static const recentFilesKey = 'pgn_viewer_recent_files';
  Future<void> _tail = Future.value();

  Future<T> _run<T>(Future<T> Function(SharedPreferences) action) {
    final result = _tail.then((_) async {
      final prefs = await preferences();
      // Rejected writes can still change the plugin's cache. Reload before a
      // read so a failed checkpoint cannot masquerade as persisted evidence.
      await prefs.reload();
      return action(prefs);
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _ack(Future<bool> write) async {
    if (!await write) throw StateError('Reading preferences were not saved');
  }

  @override
  Future<String?> lastFile() =>
      _run((prefs) async => prefs.getString(lastFileKey));

  @override
  Future<ViewerSession?> loadSession(String path) => _run(
    (prefs) async =>
        ViewerSession.decode(prefs.getString('pgn_viewer.session:$path')),
  );

  @override
  Future<void> saveSession(String path, ViewerSession session) {
    final encoded = session.encode();
    return _run((prefs) async {
      await _ack(prefs.setString('pgn_viewer.session:$path', encoded));
      await _ack(prefs.setString(lastFileKey, path));
    });
  }

  @override
  Future<void> closeSession() =>
      _run((prefs) => _ack(prefs.remove(lastFileKey)));

  @override
  Future<List<String>> loadRecentFiles() => _run(
    (prefs) async => List.unmodifiable(
      prefs.getStringList(recentFilesKey) ?? const <String>[],
    ),
  );

  @override
  Future<void> saveRecentFiles(List<String> paths) {
    final captured = List<String>.of(paths);
    return _run((prefs) => _ack(prefs.setStringList(recentFilesKey, captured)));
  }

  @override
  Future<SliceConfig?> loadSlice(String path) => _run((prefs) async {
    final raw = prefs.getString('pgn_slice:$path');
    if (raw == null) return null;
    final config = SliceConfig.fromJsonString(raw);
    return config.isEmpty ? null : config;
  });

  @override
  Future<void> saveSlice(String path, SliceConfig config) {
    final raw = config.isEmpty ? null : config.toJsonString();
    return _run(
      (prefs) => _ack(
        raw == null
            ? prefs.remove('pgn_slice:$path')
            : prefs.setString('pgn_slice:$path', raw),
      ),
    );
  }

  @override
  Future<bool> autoDetectOpenings() => _run(
    (prefs) async => prefs.getBool('pgn_viewer.auto_detect_openings') ?? true,
  );
}
