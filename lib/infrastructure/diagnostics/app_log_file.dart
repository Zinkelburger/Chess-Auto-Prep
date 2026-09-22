/// The log file behind [Log.sink]: the copy of a failure that outlives the
/// session the user was in.
///
/// The console reaches a desktop launch's journal on Linux and a terminal
/// everywhere else, neither of which a user can be asked to produce. This
/// keeps the same lines in `<support>/logs/app.log`, capped and rotated so a
/// repeating failure cannot fill the disk, and reachable from Settings.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../app_version.dart';
import '../../services/storage/app_paths.dart';
import '../../utils/log.dart';

/// Appends log lines to one file, rotating to `app.log.1` at [maxBytes].
///
/// Writes are serialized on one future chain, so lines land whole and in
/// order; every failure is swallowed, because a broken log must never break
/// the app that is reporting through it.
class AppLogFile {
  AppLogFile(this.file, {this.maxBytes = _defaultMaxBytes})
    : _bytes = file.existsSync() ? file.lengthSync() : 0;

  static const _defaultMaxBytes = 512 * 1024;
  static const directoryName = 'logs';
  static const fileName = 'app.log';

  final File file;

  /// The size at which the current file is rotated. Two files of this size
  /// is the most the log ever occupies.
  final int maxBytes;

  int _bytes;
  Future<void> _writes = Future.value();

  /// `<support>/logs`, created. Settings opens this.
  static Future<Directory> directory() async {
    final support = await AppPaths.supportDirectory();
    final dir = Directory(p.join(support.path, directoryName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Open the log and make [log] write to it, after a banner that dates the
  /// session and names the build. Returns null when the log file cannot be
  /// opened at all — the console still has every line.
  static Future<AppLogFile?> install() async {
    try {
      final dir = await directory();
      final sink = AppLogFile(File(p.join(dir.path, fileName)));
      sink.write(
        '── Chess Auto Prep $kAppVersion on '
        '${Platform.operatingSystem} ${Platform.operatingSystemVersion} ──',
      );
      Log.sink = sink.write;
      return sink;
    } catch (_) {
      return null;
    }
  }

  /// Queue [line] for appending. Returns immediately.
  void write(String line) {
    final text = '$line\n';
    _writes = _writes
        .then((_) async {
          if (_bytes + text.length > maxBytes) await _rotate();
          await file.writeAsString(text, mode: FileMode.append);
          _bytes += text.length;
        })
        .catchError((_) {});
  }

  /// Everything queued so far is on disk.
  Future<void> flush() => _writes;

  /// Keep exactly one previous log: the session before the one that is
  /// being reported is usually where the cause is.
  Future<void> _rotate() async {
    final previous = File('${file.path}.1');
    if (await previous.exists()) await previous.delete();
    if (await file.exists()) await file.rename(previous.path);
    _bytes = 0;
  }
}
