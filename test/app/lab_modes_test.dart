// The Bughouse mode is offered only once the build says it carries the
// engine, and an answer that comes after the mode is taken down is dropped.
import 'dart:async';

import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/diagnostics/log.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/features/bughouse/lab_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/viewer_fixture.dart';

void main() {
  late LabModes modes;
  late List<LogEntry> logged;
  setUp(() {
    final lab = BughouseLab();
    modes = LabModes(
      lab: lab,
      engine: LabEngine(
        lab: lab,
        startEngine: () async => throw StateError('not started here'),
      ),
      picker: ScriptedPicker(),
      files: ScriptedImport(),
    );
    logged = [];
    log.install(logged.add);
    addTearDown(() => log.remove(logged.add));
  });

  test('is offered only when the build has the engine', () async {
    expect(modes.offered.value, isFalse);
    await modes.offer(() async => false);
    expect(modes.offered.value, isFalse);
    await modes.offer(() async => true);
    expect(modes.offered.value, isTrue);
    modes.dispose();
  });

  test('an answer after it was taken down changes nothing', () async {
    final answer = Completer<bool>();
    final offering = modes.offer(() => answer.future);
    modes.dispose();
    answer.complete(true);
    await offering;
    expect(logged, isEmpty);
  });
}
