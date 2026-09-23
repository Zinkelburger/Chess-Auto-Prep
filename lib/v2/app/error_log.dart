/// Flutter's own failures into the log: a layout assertion, a build that
/// threw, an uncaught async error. The console still shows Flutter's full
/// report; `app.log` gets a compact copy, so a red console that scrolled
/// away can be read back tomorrow.
library;

import 'package:flutter/foundation.dart';

import '../diagnostics/log.dart';

/// Installs both hooks. Call once, before `runApp`; a hot restart re-runs
/// `main` and installs them again over the same globals.
void installErrorLog() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    log.e(frameworkAction(details), frameworkReport(details));
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    log.e('run', uncaughtReport(error, stack));
    // Not handled: the engine then prints its own full report, as it did
    // before this hook was installed.
    return false;
  };
}

/// What Flutter was doing, as it says it: `performLayout()`, `building
/// Foo(dirty)`; `run` when it does not say. Flutter phrases the context for
/// its own header, "thrown during performLayout()"; the "during" goes.
String frameworkAction(FlutterErrorDetails details) {
  var context = details.context?.toDescription().trim() ?? '';
  const during = 'during ';
  if (context.startsWith(during)) context = context.substring(during.length);
  return context.isEmpty ? 'run' : context;
}

/// The exception's summary, the widget Flutter blames when it names one,
/// and the frames that matter. A layout throw has no app frame at all: the
/// pipeline lays out from the root, so the blamed widget's source location
/// is the one line that says where. Continuation lines are indented so the
/// entry still starts at its timestamp.
String frameworkReport(FlutterErrorDetails details) {
  final lines = details.toString().split('\n');
  final summary = _firstLine(details.summary.toDescription());
  final widget = _blamedWidget(lines);
  return _entry(summary, [
    if (widget != null) 'widget: $widget',
    ...selectFrames(lines),
  ]);
}

/// An error nobody caught: its first line and the frames that matter.
String uncaughtReport(Object error, StackTrace stack) =>
    _entry(_firstLine('$error'), selectFrames(stack.toString().split('\n')));

/// Up to [maxFrames] stack frames, preferring the app's own: every frame
/// from `package:chess_auto_prep` first, the frames on top of the stack
/// when there are none.
List<String> selectFrames(List<String> lines, {int maxFrames = 12}) {
  final frames = [
    for (final line in lines)
      if (_frame.hasMatch(line)) line.trim(),
  ];
  final ours = [
    for (final frame in frames)
      if (frame.contains('package:chess_auto_prep/')) frame,
  ];
  final chosen = ours.isEmpty ? frames : ours;
  return chosen.take(maxFrames).toList();
}

final _frame = RegExp(r'^\s*#\d+\s');

String _firstLine(String text) {
  final trimmed = text.trim();
  final end = trimmed.indexOf('\n');
  return end < 0 ? trimmed : trimmed.substring(0, end);
}

/// Flutter prints the widget's name, then `Name:file:///…:line:col` when it
/// knows the source; the last line of that block is the one worth keeping.
String? _blamedWidget(List<String> lines) {
  const marker = 'The relevant error-causing widget was';
  final start = lines.indexWhere((l) => l.contains(marker));
  if (start < 0) return null;
  String? last;
  for (final line in lines.skip(start + 1)) {
    final candidate = line.trim();
    if (candidate.isEmpty) {
      if (last != null) break;
      continue;
    }
    last = candidate;
  }
  return last;
}

String _entry(String summary, List<String> details) =>
    [summary, for (final d in details) '  $d'].join('\n');
