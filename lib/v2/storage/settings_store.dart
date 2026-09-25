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
/// on the defaults. A symlinked `settings.json` (dotfiles) is followed for
/// reading and writing. A write that fails keeps the value on screen, says so,
/// and the next change writes again. A store made with no folder keeps
/// everything in memory, which is what a test wants.
final class SettingsStore extends ChangeNotifier {
  SettingsStore({
    Directory? support,
    Settings initial = Settings.defaults,
    this.publish = replaceFile,
  }) : _file = support == null
           ? null
           : File(p.join(support.path, 'settings.json')),
       _value = initial;

  final File? _file;

  /// Puts the bytes in place; replaceable so a test can fail a write.
  final Future<void> Function(String, List<int>) publish;
  PendingWrites? pendingWrites;
  Future<void>? _loading;
  Settings _value;
  String? _problem;
  bool _disposed = false;

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
      final text = await _target(file).readAsString();
      value = Settings.fromJson(
        text.startsWith('﻿') ? text.substring(1) : text,
      );
    } on PathNotFoundException {
      value = Settings.defaults;
    } on Object catch (error) {
      // A FormatException can include the input text; name only the kind.
      log.w('read ${file.path}', error.runtimeType);
      await _moveAside(file);
      value = Settings.defaults;
    }
    if (_disposed || edits != _edits) return;
    _value = value;
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
  Future<void> _write(File file, Settings value) async {
    try {
      final target = _target(file);
      await target.parent.create(recursive: true);
      await withDirectoryLock(
        target.parent,
        () => publish(target.path, utf8.encode(value.toJson())),
      );
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
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      ':',
      '-',
    );
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
