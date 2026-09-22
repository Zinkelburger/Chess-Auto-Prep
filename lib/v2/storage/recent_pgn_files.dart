import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/log.dart';

/// The files the PGN Viewer opened last, newest first.
///
/// The preferences are a real boundary, so this is an interface:
/// [PreferencesRecentFiles] in the app, a scripted one in tests.
abstract interface class RecentFiles {
  /// The saved paths, without the ones that are no longer on disk: a file
  /// the user deleted is not something to offer them.
  Future<RecentFilesRead> load();

  /// Whether [paths] were saved. A list that was not saved is still the one
  /// on screen; the caller says so.
  Future<bool> save(List<String> paths);
}

sealed class RecentFilesRead {
  const RecentFilesRead();
}

final class RecentFilesListed extends RecentFilesRead {
  const RecentFilesListed(this.paths);

  final List<String> paths;
}

final class RecentFilesUnreadable extends RecentFilesRead {
  const RecentFilesUnreadable(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

/// The same SharedPreferences key the old app keeps its recent files under,
/// so a file opened in either app is offered by both.
const recentPgnFilesKey = 'pgn_viewer_recent_files';

final class PreferencesRecentFiles implements RecentFiles {
  PreferencesRecentFiles({
    Future<SharedPreferences> Function() preferences =
        SharedPreferences.getInstance,
  }) : _preferences = preferences;

  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<RecentFilesRead> load() async {
    final List<String> saved;
    try {
      final prefs = await _preferences();
      saved = prefs.getStringList(recentPgnFilesKey) ?? const [];
    } on Object catch (error) {
      log.w('read the recent PGN files', error);
      return RecentFilesUnreadable('$error');
    }
    return RecentFilesListed([
      for (final path in saved)
        if (await File(path).exists()) path,
    ]);
  }

  @override
  Future<bool> save(List<String> paths) async {
    try {
      final prefs = await _preferences();
      if (await prefs.setStringList(recentPgnFilesKey, paths)) return true;
      log.w('save the recent PGN files', 'the preferences refused the write');
      return false;
    } on Object catch (error) {
      log.w('save the recent PGN files', error);
      return false;
    }
  }
}
