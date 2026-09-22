import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';

/// `<support>/logs/app.log`: one line per entry, appended across runs so
/// "an error appeared yesterday" can still be answered. A file past
/// [rotateAt] on open becomes `app.log.1`; one old generation is enough.
final class LogFile {
  LogFile(this.directory, {this.rotateAt = 2 << 20});

  final Directory directory;
  final int rotateAt;
  IOSink? _sink;

  File get file => File(p.join(directory.path, 'app.log'));

  /// Opens for appending and returns the sink to install.
  Future<LogSink> open() async {
    await directory.create(recursive: true);
    if (await file.exists() && await file.length() > rotateAt) {
      await file.rename('${file.path}.1');
    }
    // Closed in [close]; the lint cannot see a sink kept in a field.
    // ignore: close_sinks
    final sink = file.openWrite(mode: FileMode.append);
    // A log that cannot be written must not take the app down with it.
    sink.done.ignore();
    _sink = sink;
    return write;
  }

  void write(LogEntry entry) => _sink?.writeln(entry.line);

  Future<void> close() async {
    final sink = _sink;
    _sink = null;
    await sink?.flush();
    await sink?.close();
  }
}
