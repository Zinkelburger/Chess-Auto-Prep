/// Tiny logging facade for the app.
///
/// Replaces ad-hoc `print()` calls.
/// Routes through `dart:developer.log` so output is structured and filterable;
/// debug/info are suppressed in release builds while warnings/errors always
/// surface. No external dependency.
///
/// A warning or an error is also written as one plain line to the console,
/// in every build mode. `dart:developer.log` alone reaches an attached
/// debugger and nothing else, so a failure the user hit on their own machine
/// left no trace: a desktop launch records the console instead (the systemd
/// journal on Linux, the terminal elsewhere). [Log.sink] adds the log file on
/// top of that; `main` installs it, so tests and isolates write no files.
///
/// Usage:
/// ```dart
/// import 'package:chess_auto_prep/utils/log.dart';
/// log.i('Maia model initialized', name: 'Maia');
/// log.e('Init failed', name: 'Maia', error: e, stackTrace: st);
/// ```
library;

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Severity, carrying the `dart:developer` level it is reported at.
enum LogLevel {
  debug(500, 'DEBUG'),
  info(800, 'INFO'),
  warning(900, 'WARN'),
  error(1000, 'ERROR');

  const LogLevel(this.developerLevel, this.label);

  /// The `level` passed to `dart:developer.log`.
  final int developerLevel;

  /// How the level is spelled in a written log line.
  final String label;

  /// Dropped in release builds; warnings and errors always surface.
  bool get isNoise => this == debug || this == info;
}

/// Takes one formatted line of a warning or an error. Never throws, and
/// never blocks the caller.
typedef LogSink = void Function(String line);

class Log {
  const Log();

  /// Where written lines go on top of the console. Null until `main`
  /// installs the log file, so a unit test writes nothing to disk.
  static LogSink? _sink;

  /// Install (or, with null, remove) the extra destination for written
  /// lines. A test that installs one must put the previous one back.
  // ignore: unnecessary_getters_setters
  static set sink(LogSink? sink) => _sink = sink;

  // ignore: unnecessary_getters_setters
  static LogSink? get sink => _sink;

  void d(String message, {String? name}) =>
      _emit(LogLevel.debug, message, name: name);

  void i(String message, {String? name}) =>
      _emit(LogLevel.info, message, name: name);

  void w(
    String message, {
    String? name,
    Object? error,
    StackTrace? stackTrace,
  }) => _emit(
    LogLevel.warning,
    message,
    name: name,
    error: error,
    stackTrace: stackTrace,
  );

  void e(
    String message, {
    String? name,
    Object? error,
    StackTrace? stackTrace,
  }) => _emit(
    LogLevel.error,
    message,
    name: name,
    error: error,
    stackTrace: stackTrace,
  );

  void _emit(
    LogLevel level,
    String message, {
    String? name,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (kReleaseMode && level.isNoise) return;
    developer.log(
      message,
      name: name ?? 'chess_auto_prep',
      level: level.developerLevel,
      error: error,
      stackTrace: stackTrace,
    );
    if (level.isNoise) return;
    final line = formatLogLine(
      level,
      message,
      name: name,
      error: error,
      stackTrace: stackTrace,
      at: DateTime.now(),
    );
    // `debugPrint` rather than `print`: it survives a release build and
    // throttles a flood instead of stalling the UI thread on a slow pipe.
    debugPrint(line);
    final sink = _sink;
    if (sink == null) return;
    try {
      sink(line);
    } catch (_) {
      // A log that cannot be written must not take the app down with it.
    }
  }
}

/// One line per event: `2026-09-19 14:42:10 ERROR Downloads: message`,
/// with the error and its first stack frames appended.
///
/// A stack trace is kept to [_stackFrameLimit] frames: enough to name the
/// call site in a report, short enough that a repeating failure cannot fill
/// the log file with one incident.
String formatLogLine(
  LogLevel level,
  String message, {
  String? name,
  Object? error,
  StackTrace? stackTrace,
  required DateTime at,
}) {
  final buffer = StringBuffer()
    ..write(_timestamp(at))
    ..write(' ')
    ..write(level.label)
    ..write(' ')
    ..write(name ?? 'chess_auto_prep')
    ..write(': ')
    ..write(message);
  if (error != null) buffer.write('\n  $error');
  if (stackTrace != null) {
    final frames = stackTrace
        .toString()
        .split('\n')
        .where((frame) => frame.trim().isNotEmpty)
        .take(_stackFrameLimit);
    for (final frame in frames) {
      buffer.write('\n  $frame');
    }
  }
  return buffer.toString();
}

const _stackFrameLimit = 12;

String _timestamp(DateTime at) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
}

/// Global logger instance.
const log = Log();
