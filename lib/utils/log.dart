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

enum LogLevel { debug, info, warning, error }

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
    // In release builds, drop debug/info noise but keep warnings/errors.
    if (kReleaseMode && (level == LogLevel.debug || level == LogLevel.info)) {
      return;
    }
    developer.log(
      message,
      name: name ?? 'chess_auto_prep',
      level: _value(level),
      error: error,
      stackTrace: stackTrace,
    );
  }

  int _value(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return 500;
      case LogLevel.info:
        return 800;
      case LogLevel.warning:
        return 900;
      case LogLevel.error:
        return 1000;
    }
  }
}

/// Global logger instance.
const log = Log();
