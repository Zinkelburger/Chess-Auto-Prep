/// Where every folder reports what went wrong.
///
/// Pure Dart, so `engines/` can report from outside Flutter. Warnings and
/// errors go to the console in every build mode; `main_v2` installs the
/// file under `<support>/logs` before anything that can fail. Never log
/// secrets, tokens or file contents: the action and the error are enough.
library;

enum LogLevel { info, warning, error }

final class LogEntry {
  const LogEntry({
    required this.time,
    required this.level,
    required this.action,
    this.error,
  });

  final DateTime time;
  final LogLevel level;

  /// What was being done, as a verb phrase: `start stockfish-linux`.
  final String action;
  final Object? error;

  /// `2026-09-19T20:31:04.123 E start stockfish-linux: No such file`
  String get line {
    final tag = switch (level) {
      LogLevel.info => 'I',
      LogLevel.warning => 'W',
      LogLevel.error => 'E',
    };
    final detail = error == null ? '' : ': $error';
    return '${time.toIso8601String()} $tag $action$detail';
  }
}

typedef LogSink = void Function(LogEntry entry);

final class Log {
  final _sinks = <LogSink>[];

  void install(LogSink sink) => _sinks.add(sink);

  void remove(LogSink sink) => _sinks.remove(sink);

  void i(String action) => _add(LogLevel.info, action, null);

  void w(String action, [Object? error]) =>
      _add(LogLevel.warning, action, error);

  void e(String action, Object error) => _add(LogLevel.error, action, error);

  void _add(LogLevel level, String action, Object? error) {
    final entry = LogEntry(
      time: DateTime.now(),
      level: level,
      action: action,
      error: error,
    );
    // The console in every build mode, for warnings and errors.
    // ignore: avoid_print
    if (level != LogLevel.info) print(entry.line);
    for (final sink in _sinks) {
      sink(entry);
    }
  }
}

/// The one log. Global because every folder reports through it and nothing
/// but `main_v2` configures it.
final log = Log();
