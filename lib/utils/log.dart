/// Tiny logging facade for the app.
///
/// Replaces ad-hoc `print()` calls.
/// Routes through `dart:developer.log` so output is structured and filterable;
/// debug/info are suppressed in release builds while warnings/errors always
/// surface. No external dependency.
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
  debug(500),
  info(800),
  warning(900),
  error(1000);

  const LogLevel(this.developerLevel);

  /// The `level` passed to `dart:developer.log`.
  final int developerLevel;

  /// Dropped in release builds; warnings and errors always surface.
  bool get isNoise => this == debug || this == info;
}

class Log {
  const Log();

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
  }
}

/// Global logger instance.
const log = Log();
