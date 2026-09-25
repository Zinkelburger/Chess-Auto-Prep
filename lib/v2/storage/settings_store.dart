import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'file_lock.dart';
import 'pending_writes.dart';
import 'recovery_files.dart';
import 'settings.dart';

/// The settings as one value, read once from `settings.json` in the app's
/// support folder and written whole on every change.
///
/// One writer for every key. A file that cannot be read does not quietly
/// become the defaults: [problem] says so and [ready] prevents starting
/// work or editing settings until a read succeeds. A write that fails
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
  String? _attempted;
  bool _loaded = false;
  Future<void>? _loading;
  Settings _value;
  String? _problem;
  String? _readProblem;
  bool _disposed = false;
  int _revision = 0;

  /// The write in flight, and whether [_value] changed since it started.
  /// Two writes at once would share the staged copy's name, and the file
  /// published could be torn or the older of the two.
  Future<void>? _writing;
  PendingObligation<void>? _saveObligation;
  bool _dirty = false;

  Settings get value => _value;

  /// Why the file could not be read or written, or null. One sentence, for
  /// the settings page to show beside the rows.
  String? get problem => _readProblem ?? _problem;
  String? get readProblem => _readProblem;
  bool get ready => _file == null || (_loaded && _readProblem == null);

  /// Reads the file. Nothing on disk is the first run and not a problem.
  Future<void> load() =>
      _loading ??= _load().whenComplete(() => _loading = null);

  Future<void> _load() async {
    if (_disposed || _dirty || canRetry) return;
    final file = _file;
    if (file == null) return;
    final revision = ++_revision;
    try {
      final baseline = await recoveryText(file.path);
      final value = baseline == null
          ? Settings.defaults
          : Settings.fromJson(
              baseline.startsWith('\ufeff') ? baseline.substring(1) : baseline,
            );
      if (_disposed || revision != _revision || canRetry) return;
      _baseline = baseline;
      _attempted = null;
      _loaded = true;
      _value = value;
      _readProblem = null;
      _problem = null;
    } on Object catch (error) {
      if (_disposed || revision != _revision || canRetry) return;
      // A FormatException can include the input text. Settings diagnostics
      // name the failure without exporting the user's saved values.
      log.w('read ${file.path}', error.runtimeType);
      _readProblem =
          'Your settings could not be read. Restore ${file.path} and retry. '
          'The saved file has not been changed.';
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
    if (_disposed) return;
    if (next == _value) {
      if (canRetry) await retry();
      return;
    }
    if (!ready) {
      // `next` was derived before any read here could replace `_value`.
      // Only an explicit successful load lets a caller edit that baseline.
      _readProblem ??= 'Read your saved settings before editing them.';
      _notify();
      return;
    }
    _revision++;
    _value = next;
    final file = _file;
    _dirty = file != null;
    _notify();
    if (file == null) return;
    await _persist(file);
  }

  bool get canRetry => _saveObligation?.committed == false;

  Future<void> retry() async {
    final file = _file;
    if (!_disposed && file != null && canRetry) await _persist(file);
  }

  Future<void> _persist(File file) {
    if (!canRetry) {
      _saveObligation = (pendingWrites ??= PendingWrites()).accept<void>(
        resource: this,
        label: 'Settings',
        work: () => _writing ??= _writeNewest(file),
        problem: (_) => _problem,
      );
    }
    return _saveObligation!.run();
  }

  Future<void> _writeNewest(File file) async {
    _dirty = true;
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
    final baseline = _baseline;
    final attempted = _attempted;
    final loaded = _loaded;
    try {
      await file.parent.create(recursive: true);
      await withDirectoryLock(file.parent, () async {
        final current = await recoveryText(file.path);
        final next = value.toJson();
        final knownAfter =
            current == next || (attempted != null && current == attempted);
        if (!knownAfter &&
            ((!loaded && current != null) || (loaded && current != baseline))) {
          throw StateError(
            'Settings changed in another instance. Reload before editing.',
          );
        }
        // A failed acknowledgement may still have published the attempted
        // snapshot. Preserve its exact before/after bytes through retries,
        // including when a newer accepted snapshot supersedes it.
        _baseline = current;
        _loaded = true;
        _attempted = next;
        await requireUnusedRecoveryStage(file.path);
        await replaceFile(file.path, utf8.encode(next));
        _baseline = next;
        _attempted = null;
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
