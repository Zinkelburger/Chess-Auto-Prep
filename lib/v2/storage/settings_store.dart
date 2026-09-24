import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'file_lock.dart';
import 'pending_writes.dart';
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
  PendingWrites? pendingWrites;
  String? _baseline;
  bool _loaded = false;
  Settings _value;
  String? _problem;
  bool _disposed = false;

  /// The write in flight, and whether [_value] changed since it started.
  /// Two writes at once would share the staged copy's name, and the file
  /// published could be torn or the older of the two.
  Future<void>? _writing;
  bool _dirty = false;

  Settings get value => _value;

  /// Why the file could not be read or written, or null. One sentence, for
  /// the settings page to show beside the rows.
  String? get problem => _problem;

  /// Reads the file. Nothing on disk is the first run and not a problem.
  Future<void> load() async {
    final file = _file;
    if (file == null) return;
    try {
      _baseline = await file.exists() ? await file.readAsString() : null;
      _loaded = true;
      if (_baseline == null) return;
      _value = Settings.fromJson(_baseline!);
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
  ///
  /// Changes made while a write is in flight are merged: the write that
  /// follows it carries the newest value, and every caller's future
  /// completes once that is on disk.
  Future<void> update(Settings next) async {
    if (next == _value) return;
    _value = next;
    _notify();
    final file = _file;
    if (file == null) return;
    _dirty = true;
    final writing = _writing ??= _writeNewest(file);
    await (pendingWrites?.track(
          this,
          writing,
          label: 'Settings',
          problem: (_) => _problem,
        ) ??
        writing);
  }

  Future<void> _writeNewest(File file) async {
    try {
      while (_dirty) {
        _dirty = false;
        await _write(file, _value);
      }
    } finally {
      _writing = null;
    }
  }

  /// One write; its outcome decides [problem], so the last write says it.
  Future<void> _write(File file, Settings value) async {
    try {
      await file.parent.create(recursive: true);
      await withDirectoryLock(file.parent, () async {
        final current = await file.exists() ? await file.readAsString() : null;
        if ((!_loaded && current != null) ||
            (_loaded && current != _baseline)) {
          throw StateError(
            'Settings changed in another instance. Reload before editing.',
          );
        }
        final next = value.toJson();
        await replaceFile(file.path, utf8.encode(next));
        _baseline = next;
        _loaded = true;
      });
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
