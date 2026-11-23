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
/// Preferences never stop the app. A file that cannot be understood is moved
/// aside into `recovery-quarantine/` — kept, not deleted — and the app starts
/// on the defaults. A file the disk will not read stays where it is: the app
/// starts on the defaults, says so, and writes nothing over it until a read
/// succeeds. A symlinked `settings.json` (dotfiles) is followed for reading
/// and writing. A write that fails keeps the value on screen, says so, and
/// the next change writes again. A store made with no folder keeps
/// everything in memory, which is what a test wants.
final class SettingsStore extends ChangeNotifier {
  SettingsStore({
    Directory? support,
    Settings initial = Settings.defaults,
    this.publish = replaceFile,
  }) : _file = support == null
           ? null
           : File(p.join(support.path, 'settings.json')),
       _value = initial,
       _base = _keys(initial);

  final File? _file;

  /// Puts the bytes in place; replaceable so a test can fail a write.
  final Future<void> Function(String, List<int>) publish;
  PendingWrites? pendingWrites;
  Future<void>? _loading;
  Settings _value;
  String? _problem;
  bool _disposed = false;

  /// The file is there but the disk would not read it: nothing is written
  /// until a read succeeds, which every write tries again.
  bool _unread = false;

  /// What the file held, key by key, when this store last read or wrote it.
  /// A change is a key that differs from this, and a write puts only the
  /// changes over what the file holds by then: another copy of the app, or
  /// a file that could not be read at the start, keeps every other key.
  Map<String, Object?> _base;

  static Map<String, Object?> _keys(Settings value) =>
      jsonDecode(value.toJson()) as Map<String, Object?>;

  static bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

  /// Counts changes, so a read that finishes after one does not undo it.
  int _edits = 0;

  /// The write in flight, and whether [_value] changed since it started.
  /// Two writes at once would share the staged copy's name.
  Future<void>? _writing;
  bool _dirty = false;

  Settings get value => _value;

  /// Why the last write failed, or null. One sentence, for the settings page.
  String? get problem => _problem;

  /// Reads the file. Nothing on disk is the first run and not a problem.
  Future<void> load() =>
      _loading ??= _load().whenComplete(() => _loading = null);

  Future<void> _load() async {
    final file = _file;
    if (_disposed || file == null) return;
    final edits = _edits;
    Settings value;
    try {
      // readAsString drops a leading byte-order mark itself.
      value = Settings.fromJson(await _read(_target(file)));
    } on PathNotFoundException {
      value = Settings.defaults;
    } on Object catch (error) {
      if (error is FileSystemException &&
          error.osError != null &&
          !_isFolder(file)) {
        // The disk failed, which says nothing about what the file holds: it
        // stays where it is, and no change is written over it this session.
        log.w('read ${file.path}; it stays as it is', error);
        _unread = true;
        _problem =
            'Your settings could not be read, so changes are not saved: '
            '${error.osError?.message ?? error.message}';
        _notify();
        return;
      }
      // A FormatException can include the input text; name only the kind.
      log.w('read ${file.path}', error.runtimeType);
      await _moveAside(file);
      value = Settings.defaults;
    }
    if (_disposed || edits != _edits) return;
    _value = value;
    _base = _keys(value);
    if (_unread) {
      _unread = false;
      _problem = null;
    }
    _notify();
  }

  /// Whether a folder stands where the file should: something to move
  /// aside, not a disk that failed.
  static bool _isFolder(File file) {
    try {
      return FileSystemEntity.typeSync(file.path, followLinks: false) ==
          FileSystemEntityType.directory;
    } on FileSystemException {
      return false;
    }
  }

  /// The file's text. A Windows sharing violation, another program such as
  /// an antivirus or a sync client holding the file for a moment, is
  /// retried for a short while.
  Future<String> _read(File file) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await file.readAsString();
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        final busy = Platform.isWindows && const [5, 32, 33].contains(code);
        if (error is PathNotFoundException || !busy || attempt >= 20) rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Replaces the settings with [next] and writes them. The screen shows
  /// [next] at once; a write that fails is reported, not undone, because
  /// the user's choice is still their choice.
  ///
  /// Changes made while a write is in flight are merged: the write that
  /// follows it carries the newest value, and every caller's future
  /// completes once that is on disk.
  Future<void> update(Settings next) async {
    if (_disposed || next == _value) return;
    _edits++;
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
          obligation: this,
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
  /// A staged copy left by a crash is simply overwritten.
  ///
  /// The file is read again under its lock and only the keys changed here
  /// go over it, so the last copy of the app to save does not undo what
  /// another saved, and a file the disk would not read at the start is
  /// never replaced by the defaults shown in its place.
  Future<void> _write(File file, Settings value) async {
    try {
      final target = _target(file);
      await target.parent.create(recursive: true);
      final was = _base;
      Map<String, Object?>? written;
      await withDirectoryLock(target.parent, () async {
        final theirs = await _onDisk(file, target);
        if (theirs == null) return;
        final next = _over(theirs, _keys(value), was);
        final text = Settings.fromJson(jsonEncode(next)).toJson();
        await publish(target.path, utf8.encode(text));
        written = jsonDecode(text) as Map<String, Object?>;
      });
      final now = written;
      if (now == null || _disposed) return;
      _base = now;
      // What another copy saved comes up here too; what was changed here
      // since this write began stays, for the write that follows.
      final shown = Settings.fromJson(
        jsonEncode(_over(now, _keys(_value), was)),
      );
      final cleared = _problem != null;
      _unread = false;
      _problem = null;
      if (shown != _value || cleared) {
        _value = shown;
        _notify();
      }
    } on Object catch (error) {
      log.e('write ${file.path}', error);
      _problem = 'Your settings could not be saved: $error';
      _notify();
    }
  }

  /// [theirs] with the keys of [mine] that differ from [was] put over it.
  static Map<String, Object?> _over(
    Map<String, Object?> theirs,
    Map<String, Object?> mine,
    Map<String, Object?> was,
  ) => {
    ...theirs,
    for (final MapEntry(:key, :value) in mine.entries)
      if (!_same(value, was[key])) key: value,
  };

  /// What the file holds now, key by key; empty when there is none. Null
  /// when the disk will not read it, and then nothing is written. A file
  /// that is not settings is moved aside first, as when it is read at the
  /// start.
  Future<Map<String, Object?>?> _onDisk(File file, File target) async {
    try {
      final decoded = jsonDecode(await _read(target));
      if (decoded is Map<String, Object?>) return decoded;
    } on PathNotFoundException {
      return {};
    } on FileSystemException catch (error) {
      if (error.osError == null || _isFolder(file)) {
        await _moveAside(file);
        return {};
      }
      log.w('read ${file.path} before saving; it stays as it is', error);
      _unread = true;
      _problem =
          'Your settings could not be read, so changes are not saved: '
          '${error.osError?.message ?? error.message}';
      _notify();
      return null;
    } on FormatException {
      // Falls through: not settings.
    }
    await _moveAside(file);
    return {};
  }

  /// The file a symlinked `settings.json` points at, so a write replaces the
  /// target and leaves the link in place.
  File _target(File file) {
    if (!FileSystemEntity.isLinkSync(file.path)) return file;
    try {
      return File(file.resolveSymbolicLinksSync());
    } on FileSystemException {
      return file; // A dangling link: the write replaces it with a file.
    }
  }

  /// Keeps a file that could not be read under
  /// `recovery-quarantine/<time>/` in the support folder, then carries on.
  Future<void> _moveAside(File file) async {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final folder = Directory(
      p.join(file.parent.path, 'recovery-quarantine', stamp),
    );
    try {
      await folder.create(recursive: true);
      final aside = p.join(folder.path, 'settings.json');
      await FileSystemEntity.type(file.path, followLinks: false) ==
              FileSystemEntityType.directory
          ? await Directory(file.path).rename(aside)
          : await file.rename(aside);
      log.w('settings moved aside to $aside');
    } on Object catch (error) {
      log.w('move ${file.path} aside', error);
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
