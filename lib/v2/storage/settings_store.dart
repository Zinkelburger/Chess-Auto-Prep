import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'settings.dart';

/// The settings as one value, read once from `settings.json` in the app's
/// support folder and written whole on every change.
///
/// One writer for every key. A file that cannot be read does not quietly
/// become the defaults: [problem] says so, the defaults are used for the
/// session, and the first change writes a fresh file. A write that fails
/// keeps the value on screen and says so too. A store made with no folder
/// keeps everything in memory, which is what a test wants.
final class SettingsStore extends ChangeNotifier {
  SettingsStore({Directory? support, Settings initial = Settings.defaults})
    : _file = support == null
          ? null
          : File(p.join(support.path, 'settings.json')),
      _value = initial;

  final File? _file;
  Settings _value;
  String? _problem;
  bool _disposed = false;

  Settings get value => _value;

  /// Why the file could not be read or written, or null. One sentence, for
  /// the settings page to show beside the rows.
  String? get problem => _problem;

  /// Reads the file. Nothing on disk is the first run and not a problem.
  Future<void> load() async {
    final file = _file;
    if (file == null) return;
    try {
      if (!await file.exists()) return;
      _value = Settings.fromJson(await file.readAsString());
      _problem = null;
    } on Object catch (error) {
      log.w('read ${file.path}', error);
      _problem =
          'Your settings could not be read, so these are the '
          'defaults. The next change writes a fresh file.';
    }
    _notify();
  }

  /// Replaces the settings with [next] and writes them. The screen shows
  /// [next] at once; a write that fails is reported, not undone, because
  /// the user's choice is still their choice.
  Future<void> update(Settings next) async {
    if (next == _value) return;
    _value = next;
    _notify();
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await replaceFile(file.path, utf8.encode(next.toJson()));
      if (_problem != null) {
        _problem = null;
        _notify();
      }
    } on Object catch (error) {
      log.e('write ${file.path}', error);
      _problem = 'Your settings could not be saved: $error';
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
