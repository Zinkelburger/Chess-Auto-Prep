import 'package:chess_auto_prep/v2/app/error_log.dart';
import 'package:chess_auto_prep/v2/diagnostics/log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a layout assertion names what Flutter was doing, the widget '
      'it blames and where it threw', (tester) async {
    final caught = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = caught.add;
    try {
      // An Expanded inside an unbounded height: the classic layout throw.
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(children: [Expanded(child: SizedBox())]),
          ),
        ),
      );
    } finally {
      FlutterError.onError = previous;
    }
    expect(caught, isNotEmpty);
    final details = caught.first;

    expect(frameworkAction(details), 'performLayout()');
    final report = frameworkReport(details);
    final lines = report.split('\n');
    expect(
      lines.first,
      'RenderFlex children have non-zero flex but incoming height constraints '
      'are unbounded.',
    );
    // Layout has no app frame, so the widget's source location is the clue.
    final widget = lines.where((l) => l.startsWith('  widget: ')).single;
    expect(widget, startsWith('  widget: Column:file:///'));
    expect(widget, contains('error_log_test.dart:'));
    final frames = lines.where((l) => l.startsWith('  #')).toList();
    expect(frames.first, contains('RenderFlex.performLayout'));
    expect(frames.length, 12);
  });

  test('an uncaught error keeps its first line and the app frames first', () {
    final stack = StackTrace.fromString('''
#0      List.first (dart:core-patch/growable_array.dart:343:5)
#1      Foo.bar (package:flutter/src/widgets/framework.dart:10:3)
#2      Viewer.open (package:chess_auto_prep/v2/features/pgn_viewer/pgn_viewer.dart:88:20)
#3      _RootZone.runUnary (dart:async/zone.dart:1:1)
''');
    final report = uncaughtReport(
      StateError('No element\nsecond line nobody reads'),
      stack,
    );
    expect(report.split('\n'), [
      'Bad state: No element',
      '  #2      Viewer.open (package:chess_auto_prep/v2/features/pgn_viewer/pgn_viewer.dart:88:20)',
    ]);
  });

  test('without app frames the top of the stack is kept, capped', () {
    final lines = [
      for (var i = 0; i < 20; i++)
        '#$i      Frame$i (package:flutter/src/x.dart:$i:1)',
      'not a frame',
    ];
    final frames = selectFrames(lines, maxFrames: 3);
    expect(frames, [
      '#0      Frame0 (package:flutter/src/x.dart:0:1)',
      '#1      Frame1 (package:flutter/src/x.dart:1:1)',
      '#2      Frame2 (package:flutter/src/x.dart:2:1)',
    ]);
  });

  test('the action falls back to run when Flutter gives no context', () {
    final details = FlutterErrorDetails(exception: Exception('x'));
    expect(frameworkAction(details), 'run');
    expect(frameworkReport(details), 'Exception: x');
  });

  test('an uncaught error goes into the log and is still left to the '
      'console', () {
    final entries = <LogEntry>[];
    void collect(LogEntry entry) => entries.add(entry);
    final framework = FlutterError.onError;
    final platform = PlatformDispatcher.instance.onError;
    addTearDown(() {
      log.remove(collect);
      FlutterError.onError = framework;
      PlatformDispatcher.instance.onError = platform;
    });
    log.install(collect);
    installErrorLog();

    final handled = PlatformDispatcher.instance.onError!(
      StateError('lost'),
      StackTrace.fromString(
        '#0      main (package:chess_auto_prep/v2/x.dart:1:1)',
      ),
    );
    expect(handled, isFalse, reason: 'the engine prints its full report');
    expect(entries.single.level, LogLevel.error);
    expect('${entries.single.error}', startsWith('Bad state: lost'));
  });
}
