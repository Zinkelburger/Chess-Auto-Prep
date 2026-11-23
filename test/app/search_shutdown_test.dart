import 'dart:async';

import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/workspace/search/fill_states.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

/// A search and the window closing: it runs on through a close the user may
/// still back out of, and is stopped, and what it has kept, only once the
/// close goes ahead.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a search runs on through the close question and is stopped before '
      'the engines are', () async {
    final engine = Completer<EngineStart>();
    final w = WindowFixture(
      launchEngine: ({required cores, required memoryMb}) => engine.future,
    );
    addTearDown(w.dispose);
    await w.requests.open(kidMain);
    final fill = w.parts.workspace.fill;
    final run = fill.start(const FillRequest(elo: 2200));
    await pumpEventQueue();
    expect(fill.state, isA<FillRunning>());

    // The close begins, and the user stays: nothing happened to the search.
    w.parts.prepareToClose();
    expect((fill.state as FillRunning).stopping, isFalse);
    w.parts.resumeAfterClose();
    expect((fill.state as FillRunning).stopping, isFalse);

    // The close goes ahead: it is asked to pause, and waited for.
    w.parts.prepareToClose();
    var finished = false;
    final closing = w.parts.finishForClose().then((_) => finished = true);
    await pumpEventQueue();
    expect((fill.state as FillRunning).stopping, isTrue);
    expect(finished, isFalse);

    engine.complete(const StartFailed('no engine in this test'));
    await closing;
    await run;
    expect(fill.state, isNot(isA<FillRunning>()));
  });

  test('nothing is waited for when no search is running', () async {
    final w = WindowFixture();
    addTearDown(w.dispose);
    await w.parts.finishForClose();
    expect(w.requests.status, isNull);
  });
}
