import 'package:chess_auto_prep/features/bughouse/controllers/bughouse_controller.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:chess_auto_prep/features/bughouse/widgets/bughouse_analysis_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bughouse_engine.dart';

/// What a user does with an engine failure.
///
/// The person who hits one is not the person who can read it, so the only
/// thing that has to work on screen is handing the whole diagnosis over
/// without understanding or retyping any of it. That is one button, and these
/// are the tests that it is wired to the report rather than to the sentence.
void main() {
  const report = '''
Chess Auto Prep 9.9.9 — bughouse engine diagnostics
Problem     : the engine said no
Files beside the engine
  onnxruntime.dll   16149344 bytes  (size ok)''';

  late FakeBughouseEngine engine;
  late BughouseController controller;

  setUp(() {
    engine = FakeBughouseEngine();
    controller = BughouseController(engineOverride: engine);
  });

  tearDown(() => controller.dispose());

  /// Mounts the panel — which starts the analysis itself — and pumps until the
  /// pump has given up and recorded the failure.
  ///
  /// Pumped rather than awaited: inside `testWidgets` the clock is the
  /// tester's, so a bare `await Future.delayed` waits on a timer that nothing
  /// will ever fire.
  Future<void> showFailure(WidgetTester tester, Object failure) async {
    engine.failNextSearch = failure;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            // The screen mounts the panel inside a Consumer of the same
            // controller; without an equivalent here nothing rebuilds when the
            // failure is recorded and the banner never appears.
            child: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => BughouseAnalysisPanel(controller: controller),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 50 && controller.error == null; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump();
  }

  testWidgets('a failure with a report keeps the report', (tester) async {
    await showFailure(
      tester,
      BughouseEngineFailure('the engine said no', report: report),
    );
    expect(controller.error, contains('the engine said no'));
    expect(controller.errorReport, report);
  });

  /// The class name is not a fact about the user's machine, and it was the
  /// first thing on the banner: "BughouseEngineFailure: Engine exited (127)".
  testWidgets('the banner shows the sentence, not the exception class', (
    tester,
  ) async {
    await showFailure(
      tester,
      BughouseEngineFailure('the engine said no', report: report),
    );
    expect(controller.error, 'the engine said no');
    expect(controller.error, isNot(contains('BughouseEngineFailure')));
    expect(find.textContaining('BughouseEngineFailure'), findsNothing);
  });

  testWidgets('a failure without one does not invent it', (tester) async {
    await showFailure(tester, BughouseEngineFailure('plain'));
    expect(controller.error, contains('plain'));
    expect(controller.errorReport, isNull);
  });

  testWidgets('the copy button puts the whole report on the clipboard', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await showFailure(
      tester,
      BughouseEngineFailure('the engine said no', report: report),
    );

    expect(find.text('Copy diagnostics'), findsOneWidget);
    // Collapsed to begin with: the report is pages long and the banner is not
    // where anyone reads it. Copying does not require opening it.
    expect(find.text('Hide details'), findsNothing);

    await tester.tap(find.byKey(const Key('bughouse-copy-diagnostics')));
    await tester.pump();

    expect(copied, contains('the engine said no'));
    expect(copied, contains('16149344 bytes'));
    expect(find.text('Copied'), findsOneWidget);

    // The confirmation is temporary, so a second copy is never blocked by the
    // first one's tick.
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Copy diagnostics'), findsOneWidget);
  });

  testWidgets('the details can be opened without copying', (tester) async {
    await showFailure(
      tester,
      BughouseEngineFailure('the engine said no', report: report),
    );
    await tester.tap(find.byKey(const Key('bughouse-toggle-diagnostics')));
    await tester.pump();
    expect(find.text('Hide details'), findsOneWidget);
    expect(find.textContaining('Files beside the engine'), findsOneWidget);
  });

  testWidgets('a failure with no report offers no button', (tester) async {
    await showFailure(tester, BughouseEngineFailure('plain'));
    expect(find.text('Copy diagnostics'), findsNothing);
  });
}
